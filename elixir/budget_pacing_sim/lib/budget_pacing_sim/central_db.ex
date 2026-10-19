defmodule BudgetPacingSim.CentralDB do
  @moduledoc """
  Central DB process — accumulates true authoritative spend, applies the beta factor
  with per-transaction noise, and serves delayed observations to the center.

  State arrays use :array (Erlang functional array) for O(log n) indexed access.

  Indexing follows simulate.jl: index k holds the cumulative value at time (k − 1)·dt.
  Index 1 is the initial value (0.0), and the tick `now` that the Clock passes to
  `record_spend/3` is the index written. The Clock, Center and Grant ticks all use the
  same numbering, so a lookup at tick k reads exactly what was recorded for tick k.
  Reading an index that has not been written yet raises.
  """
  use GenServer

  alias BudgetPacingSim.Config

  defstruct [
    :config,
    :s_db,     # :array — cumulative true DB spend
    :ccli,     # %{client_id => :array} — per-client cumulative counted spend
    :ctot,     # :array — cumulative total client-counted spend
    latest: 1, # last index written (1 = initial value only)
    asof: 1    # monotonic: latest index served to the center as Y
  ]

  # --- Client API ---

  def start_link(%Config{} = cfg, opts \\ []) do
    GenServer.start_link(__MODULE__, cfg, opts)
  end

  def record_spend(pid, tick, spends) do
    GenServer.call(pid, {:record_spend, tick, spends})
  end

  def observe(pid, tick, d_ticks, jitter_ticks) do
    GenServer.call(pid, {:observe, tick, d_ticks, jitter_ticks})
  end

  @doc """
  True cumulative DB spend at the latest written index, with no delay. For metrics only:
  the center never sees this value. Unlike `observe/4`, it does not move the delayed view.
  """
  def true_spend(pid) do
    GenServer.call(pid, :true_spend)
  end

  def lookup(pid, client_id, index) do
    GenServer.call(pid, {:lookup, client_id, index})
  end

  def ctot(pid, index) do
    GenServer.call(pid, {:ctot, index})
  end

  # --- Callbacks ---

  @impl true
  def init(%Config{} = cfg) do
    ccli = for i <- 1..cfg.n_clients, into: %{}, do: {i, initial_array()}

    state = %__MODULE__{
      config: cfg,
      s_db: initial_array(),
      ccli: ccli,
      ctot: initial_array()
    }

    {:ok, state}
  end

  # Index 1 holds the initial value; index 0 is unused but kept at 0.0.
  defp initial_array, do: :array.set(1, 0.0, :array.set(0, 0.0, :array.new(default: 0.0)))

  # Append tick `tick`'s spend at index `tick`. Ticks must arrive in order, one per call.
  # Clients missing from `spends` keep their previous cumulative value.
  @impl true
  def handle_call({:record_spend, tick, spends}, _from, %{latest: latest} = state)
      when tick == latest + 1 do
    amounts = Map.new(spends, fn {cid, client_amount, db_amount} -> {cid, {client_amount, db_amount}} end)

    ccli =
      Map.new(state.ccli, fn {cid, arr} ->
        {client_amount, _} = Map.get(amounts, cid, {0.0, 0.0})
        {cid, :array.set(tick, :array.get(latest, arr) + client_amount, arr)}
      end)

    {client_total, db_total} =
      Enum.reduce(spends, {0.0, 0.0}, fn {_cid, c, d}, {ca, da} -> {ca + c, da + d} end)

    new_state = %{
      state
      | s_db: :array.set(tick, :array.get(latest, state.s_db) + db_total, state.s_db),
        ccli: ccli,
        ctot: :array.set(tick, :array.get(latest, state.ctot) + client_total, state.ctot),
        latest: tick
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:record_spend, tick, _spends}, _from, state) do
    raise ArgumentError, "record_spend for tick #{tick}, expected tick #{state.latest + 1}"
  end

  # Return the delayed DB observation Y = S(t − D − jitter).
  #
  # The center calls this once per tick to see the "truth" — but the truth is
  # stale by D + jitter minutes. The `asof` field enforces monotonicity: the
  # observed index never goes backwards, even if jitter would push it earlier
  # than a previous call. This matches the Julia invariant that the observed
  # time never decreases.
  #
  # Parameters:
  #   tick         — current tick (`now`)
  #   d_ticks      — base delay in ticks (D / dt)
  #   jitter_ticks — random extra delay this tick, uniform in [0, D_jitter/dt]
  #
  # Returns: the cumulative true DB spend at index max(asof, tick − d_ticks − jitter_ticks).
  @impl true
  def handle_call({:observe, tick, d_ticks, jitter_ticks}, _from, state) do
    actual = max(state.asof, max(1, tick - d_ticks - jitter_ticks))
    actual = min(actual, state.latest)
    {:reply, :array.get(actual, state.s_db), %{state | asof: actual}}
  end

  def handle_call(:true_spend, _from, state) do
    {:reply, :array.get(state.latest, state.s_db), state}
  end

  # Return client_id's cumulative counted spend at a past tick index.
  #
  # The center uses this during exposure calculation: for each unsettled grant,
  # it needs to know how much the client had counted by the "safe" index
  # (the latest index guaranteed to be included in Y). This is client-side
  # accounting — before the β factor — so it's what the client enforced
  # against its grant limit.
  #
  # Parameters:
  #   client_id — 1-based client identifier
  #   index     — 0-based tick index into the cumulative array
  #
  # Returns: ccli[client_id][index], the cumulative client-counted spend.
  @impl true
  def handle_call({:lookup, client_id, index}, _from, state) do
    check_written!(index, state)
    {:reply, :array.get(index, state.ccli[client_id]), state}
  end

  # Return the total client-counted spend (all clients summed) at a past tick index.
  #
  # The center uses this for two things:
  #   1. β̂ estimation: EWMA(ΔY) / EWMA(ΔC), where ΔC is the change in ctot
  #      aligned to the assumed delay.
  #   2. Nowcast: Ŝ = Y + β̂ · (ctot[recent] − ctot[delayed]).
  #
  # Parameters:
  #   index — 0-based tick index
  #
  # Returns: ctot[index], the cumulative sum of all clients' counted spend.
  @impl true
  def handle_call({:ctot, index}, _from, state) do
    check_written!(index, state)
    {:reply, :array.get(index, state.ctot), state}
  end

  # :array returns its default (0.0) for unwritten indices, which would silently turn a
  # read-ahead into "nothing spent". Fail loudly instead.
  defp check_written!(index, state) when index >= 0 and index <= state.latest, do: :ok

  defp check_written!(index, state) do
    raise ArgumentError, "read of index #{index}, only 0..#{state.latest} written"
  end
end

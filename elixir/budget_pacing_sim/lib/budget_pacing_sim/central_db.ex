defmodule BudgetPacingSim.CentralDB do
  @moduledoc """
  Central DB process — accumulates true authoritative spend, applies the beta factor
  with per-transaction noise, and serves delayed observations to the center.

  State arrays use :array (Erlang functional array) for O(log n) indexed access.
  Index 1 is the initial value (0.0); index k corresponds to the state after tick k-1.
  """
  use GenServer

  alias BudgetPacingSim.Config

  defstruct [
    :config,
    :s_db,     # :array — cumulative true DB spend
    :ccli,     # %{client_id => :array} — per-client cumulative counted spend
    :ctot,     # :array — cumulative total client-counted spend
    :size,     # number of entries (1 at init, grows by 1 per tick)
    asof: 1    # monotonic: latest index served to the center
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

  def lookup(pid, client_id, index) do
    GenServer.call(pid, {:lookup, client_id, index})
  end

  def ctot(pid, index) do
    GenServer.call(pid, {:ctot, index})
  end

  # --- Callbacks ---

  @impl true
  def init(%Config{} = cfg) do
    ccli =
      for i <- 1..cfg.n_clients, into: %{} do
        {i, :array.set(0, 0.0, :array.new(default: 0.0))}
      end

    state = %__MODULE__{
      config: cfg,
      s_db: :array.set(0, 0.0, :array.new(default: 0.0)),
      ccli: ccli,
      ctot: :array.set(0, 0.0, :array.new(default: 0.0)),
      size: 1
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:record_spend, _tick, spends}, _from, state) do
    idx = state.size  # new entry index (0-based)
    prev_s = :array.get(idx - 1, state.s_db)
    prev_ctot = :array.get(idx - 1, state.ctot)

    {new_s_db, new_ccli, new_ctot_val} =
      Enum.reduce(spends, {prev_s, state.ccli, prev_ctot}, fn
        {client_id, client_amount, db_amount}, {s_acc, ccli_acc, ctot_acc} ->
          prev_cli = :array.get(idx - 1, ccli_acc[client_id])
          new_cli_arr = :array.set(idx, prev_cli + client_amount, ccli_acc[client_id])
          {s_acc + db_amount, Map.put(ccli_acc, client_id, new_cli_arr), ctot_acc + client_amount}
      end)

    # Fill in clients that had no spend this tick
    new_ccli =
      Enum.reduce(state.ccli, new_ccli, fn {cid, _arr}, acc ->
        if Map.has_key?(acc, cid) and :array.size(acc[cid]) > idx do
          acc
        else
          prev_val = :array.get(idx - 1, acc[cid])
          Map.put(acc, cid, :array.set(idx, prev_val, acc[cid]))
        end
      end)

    new_state = %{
      state
      | s_db: :array.set(idx, new_s_db, state.s_db),
        ccli: new_ccli,
        ctot: :array.set(idx, new_ctot_val, state.ctot),
        size: state.size + 1
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:observe, _tick, d_ticks, jitter_ticks}, _from, state) do
    # Look back d_ticks + jitter from the latest entry
    target = max(0, state.size - 1 - d_ticks - jitter_ticks)
    # Monotonic: never go backwards
    actual = max(target, state.asof)
    # Clamp to valid range
    actual = min(actual, state.size - 1)
    y = :array.get(actual, state.s_db)
    {:reply, y, %{state | asof: actual}}
  end

  @impl true
  def handle_call({:lookup, client_id, index}, _from, state) do
    val = :array.get(index, state.ccli[client_id])
    {:reply, val, state}
  end

  @impl true
  def handle_call({:ctot, index}, _from, state) do
    val = :array.get(index, state.ctot)
    {:reply, val, state}
  end
end

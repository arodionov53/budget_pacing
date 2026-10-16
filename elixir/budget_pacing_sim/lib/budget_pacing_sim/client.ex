defmodule BudgetPacingSim.Client do
  @moduledoc """
  Client process — demand generation, token-bucket local pacing, grant lifecycle
  (request, renew, re-grant, partial return), and reporting.
  """
  use GenServer

  alias BudgetPacingSim.{Config, Grant, Model}

  defstruct [
    :id,
    :config,
    :mu,          # mean demand rate
    :phase,       # daily phase shift [min]
    logdrift: 0.0,
    grant: nil,   # %Grant{} or nil
    tokens: 0.0,
    used: 0.0,    # client-counted spend on active grant
    cum_spend: 0.0,
    request_tick: nil,  # tick when pending request was sent (nil = none)
    lam_own: 0.0        # client's own EWMA of demand rate
  ]

  # --- Client API ---

  def start_link({id, mu, phase, initial_logdrift, %Config{} = cfg}, opts \\ []) do
    GenServer.start_link(__MODULE__, {id, mu, phase, initial_logdrift, cfg}, opts)
  end

  @doc """
  Advance the client by one simulation tick.

  The Clock calls this once per tick with pre-drawn random numbers
  `{demand_noise, drift_noise}`. The client:

  1. Updates its OU drift state (slow demand wander over hours).
  2. Generates demand: d = max(0, m·dt + cv·m·√dt·ξ) where m includes
     the daily pattern, shock, and drift.
  3. Updates its own demand EWMA (lam_own, 30 min window).
  4. Spends through the token bucket: min(demand, tokens, grant remaining).
  5. Handles grant expiry if tick ≥ expiry_tick.
  6. Runs partial return — shrinks the grant amount if the client can't
     use it before expiry (rate stays unchanged).
  7. Decides whether to request a new grant (no grant, running low,
     or demand surged past regrant_threshold).

  Returns `{:ok, report}` where report is a map with:
    - spend:     client-counted spend this tick
    - demand:    raw demand this tick (what it would spend without limits)
    - cum_spend: cumulative client-counted spend across all ticks
    - request:   true if the client is asking for a new grant
    - expired_grant: the old Grant struct if one expired this tick, nil otherwise
    - returned:  amount returned via partial return (0.0 if none)
  """
  def tick(pid, tick, randoms) do
    GenServer.call(pid, {:tick, tick, randoms})
  end

  @doc """
  Install a new grant on this client.

  The Clock calls this after the Center issues a grant. If the client
  already holds an active grant, the old one is switched off: its
  switch_tick and release_tick are set to the current tick (or to
  expiry_tick if return_unused is false). The token bucket carry-over
  is capped to the new grant's burst size, and `used` resets to 0.

  Returns `{:ok, expired_grant}` where expired_grant is the old Grant
  struct with switch/release set (nil if there was no previous grant).
  The Clock forwards this to the Center for exposure bookkeeping.
  """
  def receive_grant(pid, grant, tick) do
    GenServer.call(pid, {:receive_grant, grant, tick})
  end

  @doc """
  Return the client's full internal state. Used by the Clock to read
  client metadata (e.g. for building the requesting_clients map) and
  by tests for assertions.
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # --- Callbacks ---

  @impl true
  def init({id, mu, phase, initial_logdrift, %Config{} = cfg}) do
    state = %__MODULE__{
      id: id,
      config: cfg,
      mu: mu,
      phase: phase,
      logdrift: initial_logdrift,
      lam_own: 0.0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:tick, tick, {demand_noise, drift_noise}}, _from, state) do
    cfg = state.config
    dt = cfg.dt
    t = (tick - 1) * dt

    # ---- OU drift update ----
    logdrift =
      state.logdrift -
        state.logdrift * dt / cfg.drift_tau +
        cfg.drift_sigma * :math.sqrt(2.0 * dt / cfg.drift_tau) * drift_noise

    # ---- demand ----
    m =
      state.mu *
        Model.base_pattern(cfg, t, state.phase) *
        Model.shock(cfg, t) *
        :math.exp(logdrift - cfg.drift_sigma * cfg.drift_sigma / 2.0)

    d = max(0.0, m * dt + cfg.noise_cv * m * :math.sqrt(dt) * demand_noise)

    # ---- EWMA of own demand ----
    alpha = if tick == 1, do: 1.0, else: dt / cfg.ewma_minutes
    lam_own = state.lam_own + alpha * (d / dt - state.lam_own)

    # ---- spend through token bucket + expiry ----
    {spend, tokens, used, grant, expired_grant} =
      case state.grant do
        nil ->
          {0.0, state.tokens, state.used, nil, nil}

        %Grant{} = g ->
          if tick >= g.expiry_tick do
            # Grant expired
            expired = %Grant{g | switch_tick: tick, release_tick: tick}
            {0.0, 0.0, 0.0, nil, expired}
          else
            new_tokens = min(
              state.tokens + g.rate * dt,
              g.rate * max(cfg.burst_minutes, dt)
            )
            s = min(d, min(new_tokens, g.amount - state.used))
            s = max(s, 0.0)
            {s, new_tokens - s, state.used + s, g, nil}
          end
      end

    # ---- partial return (only if grant is still active) ----
    {grant, returned} =
      case grant do
        %Grant{} = g when cfg.return_unused and cfg.return_keep_factor > 0 ->
          remaining_ticks = g.expiry_tick - tick
          keep = cfg.return_keep_factor * min(g.rate, lam_own) * remaining_ticks * dt
          excess = g.amount - used - keep

          if excess > max(cfg.min_grant, 0.1 * g.amount) do
            new_amount = g.amount - excess
            {%Grant{g | amount: new_amount}, excess}
          else
            {g, 0.0}
          end

        _ ->
          {grant, 0.0}
      end

    cum_spend = state.cum_spend + spend

    # ---- check if grant request needed ----
    {needs_request, request_tick} =
      cond do
        # Already have a pending request
        state.request_tick != nil ->
          {false, state.request_tick}

        # No grant
        grant == nil ->
          {true, tick}

        # Grant active — check conditions
        true ->
          g = grant
          time_left = (g.expiry_tick - tick) * dt
          money_left = g.amount - used

          cond do
            time_left <= cfg.renew_lead ->
              {true, tick}

            money_left <= g.rate * cfg.renew_lead ->
              {true, tick}

            g.lam_issue > 1.0e-15 and lam_own / g.lam_issue > 1.0 + cfg.regrant_threshold ->
              {true, tick}

            true ->
              {false, nil}
          end
      end

    new_state = %{
      state
      | logdrift: logdrift,
        grant: grant,
        tokens: tokens,
        used: used,
        cum_spend: cum_spend,
        request_tick: request_tick,
        lam_own: lam_own
    }

    report = %{
      spend: spend,
      demand: d,
      cum_spend: cum_spend,
      request: needs_request and state.request_tick == nil,
      expired_grant: expired_grant,
      returned: returned
    }

    {:reply, {:ok, report}, new_state}
  end

  @impl true
  def handle_call({:receive_grant, %Grant{} = new_grant, tick}, _from, state) do
    cfg = state.config

    # Handle replacement of old grant
    expired_grant =
      case state.grant do
        %Grant{} = old ->
          %Grant{
            old
            | switch_tick: tick,
              release_tick: if(cfg.return_unused, do: tick, else: old.expiry_tick)
          }

        nil ->
          nil
      end

    # Cap token carry-over to new rate's burst
    tokens = min(state.tokens, new_grant.rate * max(cfg.burst_minutes, cfg.dt))

    new_state = %{
      state
      | grant: new_grant,
        tokens: tokens,
        used: 0.0,
        request_tick: nil
    }

    {:reply, {:ok, expired_grant}, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end

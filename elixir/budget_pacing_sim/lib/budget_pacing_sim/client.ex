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
    t = (tick - 1) * cfg.dt

    logdrift = update_drift(state.logdrift, drift_noise, cfg)
    d = demand(state, logdrift, t, demand_noise, cfg)
    lam_own = update_lam_own(state.lam_own, d, tick, cfg)

    {spend, tokens, used, grant, expired_grant} = spend_from_grant(state, d, tick, cfg)
    {grant, returned} = partial_return(grant, used, lam_own, tick, cfg)
    cum_spend = state.cum_spend + spend

    {needs_request, request_tick} =
      request_decision(state.request_tick, grant, used, lam_own, tick, cfg)

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

  # --- Tick steps ---

  # OU drift: slow mean-reverting wander of the demand level.
  defp update_drift(logdrift, drift_noise, cfg) do
    dt = cfg.dt

    logdrift -
      logdrift * dt / cfg.drift_tau +
      cfg.drift_sigma * :math.sqrt(2.0 * dt / cfg.drift_tau) * drift_noise
  end

  # Demand this tick: pattern × shock × drift, plus Gaussian noise, clipped at 0.
  defp demand(state, logdrift, t, demand_noise, cfg) do
    dt = cfg.dt

    m =
      state.mu *
        Model.base_pattern(cfg, t, state.phase) *
        Model.shock(cfg, t) *
        :math.exp(logdrift - cfg.drift_sigma * cfg.drift_sigma / 2.0)

    max(0.0, m * dt + cfg.noise_cv * m * :math.sqrt(dt) * demand_noise)
  end

  # EWMA of own demand; the first tick initializes it directly.
  defp update_lam_own(lam_own, d, tick, cfg) do
    alpha = if tick == 1, do: 1.0, else: cfg.dt / cfg.ewma_minutes
    lam_own + alpha * (d / cfg.dt - lam_own)
  end

  # Spend through the token bucket, or expire the grant.
  # Returns {spend, tokens, used, grant, expired_grant}.
  defp spend_from_grant(%{grant: nil} = state, _d, _tick, _cfg) do
    {0.0, state.tokens, state.used, nil, nil}
  end

  defp spend_from_grant(%{grant: %Grant{} = g}, _d, tick, _cfg) when tick >= g.expiry_tick do
    {0.0, 0.0, 0.0, nil, %Grant{g | switch_tick: tick, release_tick: tick}}
  end

  defp spend_from_grant(%{grant: %Grant{} = g} = state, d, _tick, cfg) do
    new_tokens = min(state.tokens + g.rate * cfg.dt, g.rate * max(cfg.burst_minutes, cfg.dt))
    s = max(min(d, min(new_tokens, g.amount - state.used)), 0.0)
    {s, new_tokens - s, state.used + s, g, nil}
  end

  # Partial return: shrink the amount to what the client can use before expiry.
  # The rate is unchanged. Returns {grant, returned_amount}.
  defp partial_return(%Grant{} = g, used, lam_own, tick, cfg)
       when cfg.return_unused and cfg.return_keep_factor > 0 do
    keep = cfg.return_keep_factor * min(g.rate, lam_own) * (g.expiry_tick - tick) * cfg.dt
    excess = g.amount - used - keep

    if excess > max(cfg.min_grant, 0.1 * g.amount) do
      {%Grant{g | amount: g.amount - excess}, excess}
    else
      {g, 0.0}
    end
  end

  defp partial_return(grant, _used, _lam_own, _tick, _cfg), do: {grant, 0.0}

  # Decide whether to request a grant. Returns {needs_request, request_tick}.
  defp request_decision(pending, _grant, _used, _lam_own, _tick, _cfg) when pending != nil,
    do: {false, pending}

  defp request_decision(nil, nil, _used, _lam_own, tick, _cfg), do: {true, tick}

  defp request_decision(nil, %Grant{} = g, used, lam_own, tick, cfg) do
    if needs_renewal?(g, used, lam_own, tick, cfg), do: {true, tick}, else: {false, nil}
  end

  # Should a client that holds grant `g` ask the center for a new one?
  #
  # True when any of three conditions holds (MODEL.md §4.4):
  #
  #   1. Time running out: fewer than `renew_lead` minutes (default 3) remain
  #      before the grant expires.
  #   2. Money running out: the unspent amount (`amount − used`) would last fewer
  #      than `renew_lead` minutes at the grant rate.
  #   3. Demand surge (re-grant): the client's own demand EWMA `lam_own` has risen
  #      more than `regrant_threshold` (default 30 %) above `lam_issue`, the demand
  #      estimate the grant was sized for. A grant's rate is fixed at issue, so
  #      without this the client would stay throttled until expiry.
  #      The `lam_issue > 1.0e-15` check avoids dividing by zero.
  #
  # `renew_lead` must exceed `grant_latency` (1 min) so the new grant arrives
  # before the old one runs dry. Conditions 1 and 2 are renewals; condition 3
  # is a re-grant. The center handles both the same way: the new grant replaces
  # the old one.
  defp needs_renewal?(g, used, lam_own, tick, cfg) do
    (g.expiry_tick - tick) * cfg.dt <= cfg.renew_lead or
      g.amount - used <= g.rate * cfg.renew_lead or
      (g.lam_issue > 1.0e-15 and lam_own / g.lam_issue > 1.0 + cfg.regrant_threshold)
  end
end

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

  def tick(pid, tick, randoms) do
    GenServer.call(pid, {:tick, tick, randoms})
  end

  def receive_grant(pid, grant, tick) do
    GenServer.call(pid, {:receive_grant, grant, tick})
  end

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

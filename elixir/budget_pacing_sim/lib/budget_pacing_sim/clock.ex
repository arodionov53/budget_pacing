defmodule BudgetPacingSim.Clock do
  @moduledoc """
  Simulation clock — deterministic discrete-tick driver that advances all processes
  in lock-step, manages the seeded RNG, and controls the run lifecycle.
  """
  alias BudgetPacingSim.{Config, CentralDB, Center, Client}

  defstruct [
    :config,
    :client_pids,   # list of client pids (1-indexed by position)
    :center_pid,
    :db_pid,
    :clients_meta,  # [{mu, phase, logdrift}] for world generation
    # metrics
    total_demand: 0.0,
    total_possible: 0.0,
    issued: 0,
    denied: 0,
    issued_amount: 0.0,
    returned: 0.0,
    regrants: 0,
    max_commit: 0.0,
    finish_time: nil,
    # time series
    ts: [],
    rec_demand: 0.0,
    rec_spend: 0.0
  ]

  # --- Public API ---

  @doc """
  Run a full simulation synchronously. Returns `{summary, time_series}`.

  This is the main entry point. It executes the complete lifecycle:

  1. **Validate config** — raises on invalid parameters, warns on safety concerns.
  2. **Seed RNG** — Erlang `:exsss` algorithm, seeded deterministically from `cfg.seed`.
     All random draws happen centrally in the tick loop (not inside GenServers),
     so the same seed + config always produces the same results.
  3. **Generate world** — lognormal client sizes (many small, few large), per-client
     phase shifts and initial OU drift states. Sizes are normalized so total mean
     demand equals `demand_ratio × B/T`.
  4. **Start GenServers** — one CentralDB, one Center, N Clients. Each gets the
     config at init. No supervision tree — if any process crashes, the run fails.
  5. **Tick loop** — `T/dt` ticks (default 10,080 = 7 days × 1,440 min/day).
     Each tick is four synchronous steps:
       a. Tick all clients (demand, spend, report)
       b. Record spend in CentralDB (apply β noise)
       c. Tick the Center (estimate, pace, issue grants)
       d. Deliver grants to clients
  6. **Collect summary** — spend_ratio, overspend, grants_per_min, utilization,
     estimation errors, finish_early, alert_minutes, etc.
  7. **Stop all GenServers** — clean shutdown.

  The time series (list of maps, one per `record_every` ticks) is collected
  during the tick loop. Pass `record_every: 0` in config to disable it.

  ## Examples

      cfg = Config.new()
      {summary, ts} = Clock.run(cfg)
      summary.spend_ratio  #=> ~1.0

      # Short run, no recording
      {summary, []} = Clock.run(Config.new(t: 100.0, record_every: 0))
  """
  def run(%Config{} = cfg) do
    cfg = Config.validate!(cfg)

    # Seed RNG
    :rand.seed(:exsss, {cfg.seed, cfg.seed * 7 + 1, cfg.seed * 13 + 3})

    # Generate world
    {clients_meta, _norm} = generate_world(cfg)

    # Start servers
    {:ok, db_pid} = CentralDB.start_link(cfg)
    {:ok, center_pid} = Center.start_link(cfg)

    client_pids =
      Enum.map(clients_meta, fn {id, mu, phase, logdrift} ->
        {:ok, pid} = Client.start_link({id, mu, phase, logdrift, cfg})
        pid
      end)

    # Run tick loop
    state = %__MODULE__{
      config: cfg,
      client_pids: client_pids,
      center_pid: center_pid,
      db_pid: db_pid,
      clients_meta: clients_meta
    }

    n_ticks = round(cfg.t / cfg.dt)
    state = run_ticks(state, 1, n_ticks)

    # Collect final metrics
    center_state = Center.get_state(center_pid)
    s_final = CentralDB.observe(db_pid, n_ticks + 1, 0, 0)

    summary = build_summary(state, center_state, s_final, cfg, n_ticks)
    ts = Enum.reverse(state.ts)

    # Stop servers
    for pid <- client_pids, do: GenServer.stop(pid)
    GenServer.stop(center_pid)
    GenServer.stop(db_pid)

    {summary, ts}
  end

  # --- World generation (matches simulate.jl lines 20-25) ---

  defp generate_world(cfg) do
    dt = cfg.dt
    n_ticks = round(cfg.t / dt)

    # Compute normalization: mean of base_pattern over all ticks, phase=0
    norm =
      Enum.reduce(1..n_ticks, 0.0, fn n, acc ->
        t = (n - 1) * dt
        acc + BudgetPacingSim.Model.base_pattern(cfg, t, 0.0)
      end) / n_ticks

    # Generate client sizes (lognormal)
    nc = cfg.n_clients
    w = for _ <- 1..nc, do: :math.exp(cfg.size_spread * :rand.normal())
    w_sum = Enum.sum(w)
    w = Enum.map(w, &(&1 / w_sum))

    total_mu = cfg.demand_ratio * cfg.b / cfg.t

    clients_meta =
      Enum.with_index(w, 1)
      |> Enum.map(fn {wi, id} ->
        mu = total_mu * wi / norm
        phase = cfg.daily_phase_jitter * :rand.normal()
        logdrift = cfg.drift_sigma * :rand.normal()
        {id, mu, phase, logdrift}
      end)

    {clients_meta, norm}
  end

  # --- Tick loop ---

  defp run_ticks(state, tick, n_ticks) when tick > n_ticks, do: state

  defp run_ticks(state, tick, n_ticks) do
    cfg = state.config
    dt = cfg.dt
    nc = cfg.n_clients
    now = tick + 1

    # Draw all randoms for this tick
    demand_noises = for _ <- 1..nc, do: :rand.normal()
    drift_noises = for _ <- 1..nc, do: :rand.normal()
    beta_noises = for _ <- 1..nc, do: :rand.normal()

    d_ticks = round(cfg.d_delay / dt)
    j_ticks = if cfg.d_jitter > 0, do: :rand.uniform(round(cfg.d_jitter / dt) + 1) - 1, else: 0

    # ===== Step 1: Tick all clients =====
    client_reports =
      Enum.zip([state.client_pids, demand_noises, drift_noises])
      |> Enum.map(fn {pid, dn, drn} ->
        {:ok, report} = Client.tick(pid, now, {dn, drn})
        report
      end)

    # ===== Step 2: Record spend in DB =====
    spends =
      Enum.zip([1..nc, client_reports, beta_noises])
      |> Enum.map(fn {cid, report, bn} ->
        factor = cfg.beta_true * (1.0 + cfg.beta_noise * clamp(bn, -3.0, 3.0))
        {cid, report.spend, report.spend * factor}
      end)

    :ok = CentralDB.record_spend(state.db_pid, now, spends)

    # ===== Step 3: Center observes and acts =====
    y = CentralDB.observe(state.db_pid, now, d_ticks, j_ticks)

    # Aligned indices for beta estimation and nowcast
    d_assumed_ticks = round(Config.d_assumed(cfg) / dt)
    rep_ticks = round(cfg.report_lag / dt)
    rep_idx = max(0, now - rep_ticks)
    a_est = max(0, min(now - d_assumed_ticks, rep_idx))

    ctot_aligned = CentralDB.ctot(state.db_pid, a_est)
    ctot_rep = CentralDB.ctot(state.db_pid, rep_idx)
    s_db_now = CentralDB.observe(state.db_pid, now, 0, 0)

    # Build ccli lookup function
    db_pid = state.db_pid
    ccli_fn = fn client_id, index -> CentralDB.lookup(db_pid, client_id, index) end

    # Reports for estimation (use lagged data)
    lagged_reports =
      Enum.map(client_reports, fn r -> %{demand: r.demand} end)

    # Determine which clients are requesting grants
    # Also build the client-id -> center's lam mapping
    center_state = Center.get_state(state.center_pid)

    requesting_clients =
      client_reports
      |> Enum.with_index(1)
      |> Enum.filter(fn {report, _idx} -> report.request end)
      |> Enum.map(fn {_report, idx} ->
        # idx is 1-based, matching CentralDB client IDs
        old_grant_idx =
          Enum.find_index(center_state.grants, fn g ->
            g.client == idx and g.switch_tick == nil
          end)

        {idx, %{lam: Enum.at(center_state.lam, idx - 1, 0.0), old_grant_idx: old_grant_idx}}
      end)
      |> Map.new()

    # Random permutation for grant ordering
    perm =
      Map.keys(requesting_clients)
      |> Enum.shuffle()

    tick_data = %{
      tick: now,
      reports: lagged_reports,
      y_obs: y,
      ctot_aligned: ctot_aligned,
      ctot_rep: ctot_rep,
      s_db_now: s_db_now,
      ccli_fn: ccli_fn,
      requesting_clients: requesting_clients,
      perm: perm
    }

    {:ok, center_result} = Center.tick(state.center_pid, tick_data)

    # ===== Step 4: Deliver grants to clients =====
    for grant <- center_result.grants_for_clients do
      # grant.client is 1-based; client_pids is 0-indexed
      client_pid = Enum.at(state.client_pids, grant.client - 1)
      if client_pid, do: Client.receive_grant(client_pid, grant, now)
    end

    # ===== Accumulate metrics =====
    dem_step = Enum.sum(Enum.map(client_reports, & &1.demand))
    sdb_step = Enum.sum(Enum.map(spends, fn {_, _, db} -> db end))
    total_demand = state.total_demand + dem_step
    total_possible = state.total_possible + dem_step * cfg.beta_true

    finish_time =
      if state.finish_time == nil and s_db_now >= 0.999 * cfg.b do
        now * dt
      else
        state.finish_time
      end

    # Time series recording
    rec_demand = state.rec_demand + dem_step * cfg.beta_true
    rec_spend = state.rec_spend + sdb_step

    ts =
      if cfg.record_every > 0 and rem(tick, cfg.record_every) == 0 do
        span = cfg.record_every * dt

        entry = %{
          t: now * dt,
          s: s_db_now,
          y: y,
          s_hat: center_result.s_hat,
          e: center_result.e,
          demand: rec_demand / span,
          spend: rec_spend / span,
          p: center_result.p,
          beta_hat: center_result.beta_hat
        }

        [entry | state.ts]
      else
        state.ts
      end

    {rec_demand, rec_spend} =
      if cfg.record_every > 0 and rem(tick, cfg.record_every) == 0 do
        {0.0, 0.0}
      else
        {rec_demand, rec_spend}
      end

    new_state = %{
      state
      | total_demand: total_demand,
        total_possible: total_possible,
        issued: state.issued + center_result.issued,
        denied: state.denied + center_result.denied,
        issued_amount: state.issued_amount + center_result.issued_amount,
        max_commit: max(state.max_commit, center_result.max_commit),
        finish_time: finish_time,
        ts: ts,
        rec_demand: rec_demand,
        rec_spend: rec_spend
    }

    run_ticks(new_state, tick + 1, n_ticks)
  end

  # --- Summary ---

  defp build_summary(state, center_state, s_final, cfg, n_ticks) do
    %{
      spend_ratio: s_final / cfg.b,
      overspend: if(s_final - cfg.b > 1.0e-9 * cfg.b, do: s_final - cfg.b, else: 0.0),
      underspend: max(cfg.b - s_final, 0.0),
      possible_ratio: state.total_possible / cfg.b,
      max_commit: state.max_commit,
      grants: state.issued,
      grants_per_min: state.issued / cfg.t,
      denied: state.denied,
      utilization:
        if state.issued_amount > 0 do
          # Approximate: total client-counted spend / total issued amount
          # We use spend_ratio * B / beta_true as total client spend
          s_final / cfg.beta_true / max(state.issued_amount, 1.0e-15)
        else
          0.0
        end,
      est_err: center_state.err_hat / n_ticks / cfg.b,
      naive_err: center_state.err_naive / n_ticks / cfg.b,
      beta_hat: center_state.beta_hat,
      finish_early:
        if state.finish_time do
          cfg.t - state.finish_time
        else
          nil
        end,
      alert_first: center_state.alert_first,
      alert_minutes: center_state.alert_minutes
    }
  end

  defp clamp(val, lo, hi), do: max(lo, min(val, hi))
end

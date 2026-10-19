defmodule BudgetPacingSim.Center do
  @moduledoc """
  Center process — estimation (demand EWMA, daily profile, level factor, beta_hat, nowcast),
  pacing law (uniform / adaptive), hard-cap invariant, exposure accounting, and grant issuance.
  """
  use GenServer

  alias BudgetPacingSim.{Config, Grant, Model}

  @day 1440.0

  defstruct [
    :config,
    grants: [],           # all grants ever issued
    unsettled: [],        # indices into grants that may still add DB spend
    lam: [],              # per-client demand rate estimate
    lam_long: 0.0,        # ~1 day EWMA of total demand
    initialized: false,
    beta_hat: 1.0,
    ew_dy: 0.0,
    ew_dc: 0.0,
    prev_y: 0.0,
    prev_c: 0.0,
    profile: [],          # learned daily profile
    seen: [],             # which bins have been seen
    cur_bin: 0,
    bin_acc: 0.0,
    bin_cnt: 0,
    level: 1.0,
    # metrics accumulators
    err_hat: 0.0,
    err_naive: 0.0,
    alert_first: nil,
    alert_minutes: 0.0
  ]

  # --- Client API ---

  def start_link(%Config{} = cfg, opts \\ []) do
    GenServer.start_link(__MODULE__, cfg, opts)
  end

  @doc """
  Run one tick of the center's decision cycle.

  The Clock calls this once per tick after all clients have acted and
  spend has been recorded in the DB. The tick_data map contains:

    - tick:                current tick index
    - reports:             list of %{demand: d} per client (lagged by report_lag)
    - y_obs:               delayed DB observation Y = S(t − D − jitter)
    - ctot_aligned:        total client-counted spend at the delay-aligned index
    - ctot_rep:            total client-counted spend at the report index
    - s_db_now:            true DB spend (for error measurement only — center doesn't use it)
    - ccli_fn:             fn(client_id, index) -> cumulative client spend (for exposure)
    - requesting_clients:  %{client_id => %{lam: ..., old_grant_idx: ...}} for clients wanting grants
    - perm:                shuffled list of requesting client_ids (grant ordering)

  The center performs, in order:

    1. Demand estimation — per-client λ̂ EWMA, long-run demand, daily profile, level factor
    2. β̂ estimation — EWMA(ΔY) / EWMA(ΔC)
    3. Nowcast — Ŝ = Y + β̂ · (C_recent − C_delayed)
    4. Pacing law — compute throttle p (uniform or adaptive)
    5. Feasibility alert — check if expected demand can fill remaining budget
    6. Exposure accounting — sum upper bounds on unsettled grants, prune settled ones
    7. Grant issuance — for each requester: size the grant, check hard cap, issue or deny

  Returns `{:ok, result}` where result is a map with:
    - s_hat:              nowcast estimate of true spend
    - p:                  effective throttle (capped at 1 + demand_headroom)
    - rstar:              target spend rate in DB units
    - beta_hat:           current β̂ estimate
    - e:                  total exposure E
    - feasibility:        ratio of expected demand to remaining budget
    - issued / denied:    grant counts this tick
    - issued_amount:      total granted amount this tick
    - max_commit:         (Y + E) / B — how close to the cap
    - expired_grants:     old grants that were replaced
    - grants_for_clients: list of new Grant structs to deliver to clients
  """
  def tick(pid, tick_data) do
    GenServer.call(pid, {:tick, tick_data}, :infinity)
  end

  @doc """
  Return the center's full internal state. Used by the Clock to read
  the grant list and demand estimates (for building requesting_clients),
  and to collect error/alert metrics at end of run. Also used by tests.
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # --- Callbacks ---

  @impl true
  def init(%Config{} = cfg) do
    state = %__MODULE__{
      config: cfg,
      lam: List.duplicate(0.0, cfg.n_clients),
      profile: List.duplicate(0.0, cfg.profile_bins),
      seen: List.duplicate(false, cfg.profile_bins)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:tick, data}, _from, state) do
    cfg = state.config
    tick = data.tick
    y = data.y_obs

    # ======= estimation =======
    state =
      state
      |> update_demand(cfg, data.reports, (tick - 1) * cfg.dt, cfg.dt)
      |> update_beta(cfg, y, data.ctot_aligned, cfg.dt)

    s_hat = nowcast(state, data, cfg)

    # ======= pacing =======
    plan = plan(state, s_hat, tick, cfg)
    {alert_first, alert_minutes} = update_alert(state, plan, tick, cfg)

    # ======= exposure =======
    {e_total, unsettled} =
      compute_exposure(state.grants, state.unsettled, data.ccli_fn, tick, cfg)

    # ======= grant issuance =======
    issue_ctx = %{
      requesting_clients: data.requesting_clients,
      p: plan.p,
      tau_st: grant_ticks(plan.t_rem, cfg),
      tick: tick,
      n_ticks: round(cfg.t / cfg.dt),
      y: y,
      cap: plan.cap,
      ccli_fn: data.ccli_fn,
      lam: state.lam,
      s: safe_index(tick, cfg),
      cfg: cfg
    }

    issued = issue_grants(data.perm, issue_ctx, state.grants, unsettled, e_total)

    state = %{
      state
      | grants: issued.grants,
        unsettled: issued.unsettled,
        err_hat: state.err_hat + abs(s_hat - data.s_db_now),
        err_naive: state.err_naive + abs(y - data.s_db_now),
        alert_first: alert_first,
        alert_minutes: alert_minutes
    }

    p_eff = min(plan.p, 1.0 + cfg.demand_headroom)

    result = %{
      s_hat: s_hat,
      p: p_eff,
      rstar: p_eff * plan.lam_tot * state.beta_hat,
      beta_hat: state.beta_hat,
      e: issued.e,
      feasibility: plan.feasibility,
      issued: issued.issued,
      denied: issued.denied,
      issued_amount: issued.issued_amount,
      max_commit: (y + issued.e) / cfg.b,
      expired_grants: issued.expired_grants,
      grants_for_clients: extract_new_grants(issued.grants, issued.issued)
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # --- Estimation ---

  # reports: list of %{demand: d} per client (0-indexed by client_id - 1)
  defp update_demand(state, cfg, reports, t, dt) do
    demands = Enum.map(reports, & &1.demand)
    tot = Enum.sum(demands) / dt

    {lam, lam_long} = update_lam(state, demands, tot, cfg, dt)
    b = Model.bin_of(cfg, t)
    level = update_level(state, b, tot, cfg, dt)
    {profile, seen, cur_bin, bin_acc, bin_cnt} = roll_profile_bin(state, b, cfg)

    %{
      state
      | lam: lam,
        lam_long: lam_long,
        initialized: true,
        level: level,
        profile: profile,
        seen: seen,
        cur_bin: cur_bin,
        bin_acc: bin_acc + tot,
        bin_cnt: bin_cnt + 1
    }
  end

  # Per-client demand EWMA and long-run total; the first report initializes them directly.
  defp update_lam(%{initialized: false}, demands, tot, _cfg, dt) do
    {Enum.map(demands, &(&1 / dt)), tot}
  end

  defp update_lam(state, demands, tot, cfg, dt) do
    alpha = dt / cfg.ewma_minutes

    lam =
      Enum.zip(state.lam, demands)
      |> Enum.map(fn {old, d} -> old + alpha * (d / dt - old) end)

    {lam, state.lam_long + dt / @day * (tot - state.lam_long)}
  end

  # Level factor: EWMA of current total demand / learned profile value for this bin.
  defp update_level(state, b, tot, cfg, dt) do
    prof = Enum.at(state.profile, b - 1)

    if cfg.level_minutes > 0 and Enum.at(state.seen, b - 1) and prof > 0 do
      state.level + dt / cfg.level_minutes * (tot / prof - state.level)
    else
      state.level
    end
  end

  # On entering a new bin, fold the finished bin's average into the profile.
  # Returns {profile, seen, cur_bin, bin_acc, bin_cnt}.
  defp roll_profile_bin(%{cur_bin: b} = state, b, _cfg) do
    {state.profile, state.seen, state.cur_bin, state.bin_acc, state.bin_cnt}
  end

  defp roll_profile_bin(state, b, cfg) do
    {profile, seen} = close_bin(state, cfg)
    {profile, seen, b, 0.0, 0}
  end

  defp close_bin(%{cur_bin: cur, bin_cnt: cnt} = state, cfg) when cur != 0 and cnt > 0 do
    p_idx = cur - 1
    avg = state.bin_acc / cnt

    new_val =
      if Enum.at(state.seen, p_idx) do
        (1.0 - cfg.profile_alpha) * Enum.at(state.profile, p_idx) + cfg.profile_alpha * avg
      else
        avg
      end

    {List.replace_at(state.profile, p_idx, new_val), List.replace_at(state.seen, p_idx, true)}
  end

  defp close_bin(state, _cfg), do: {state.profile, state.seen}

  defp update_beta(state, cfg, y, c_aligned, dt) do
    alpha = dt / cfg.beta_ewma_minutes
    ew_dy = state.ew_dy + alpha * ((y - state.prev_y) - state.ew_dy)
    ew_dc = state.ew_dc + alpha * ((c_aligned - state.prev_c) - state.ew_dc)

    beta_hat = if ew_dc > 1.0e-9, do: ew_dy / ew_dc, else: state.beta_hat

    %{state | ew_dy: ew_dy, ew_dc: ew_dc, prev_y: y, prev_c: c_aligned, beta_hat: beta_hat}
  end

  # Ŝ = Y + β̂ · (reported spend in the blind window), or just Y when nowcast is off.
  defp nowcast(_state, data, %{nowcast: :none}), do: data.y_obs

  defp nowcast(state, data, _cfg) do
    data.y_obs + state.beta_hat * (data.ctot_rep - data.ctot_aligned)
  end

  # --- Pacing ---

  # Remaining budget, target rate r*, throttle p, and feasibility for this tick.
  defp plan(state, s_hat, tick, cfg) do
    now_t = tick * cfg.dt
    cap = cfg.b * (1.0 - cfg.delta)
    r_remaining = max(cap - s_hat, 0.0)
    lam_tot = Enum.sum(state.lam)
    t_rem = cfg.t - now_t

    rstar = target_rate(state, r_remaining, lam_tot, t_rem, now_t, cfg)

    lam_rem =
      Model.remaining_demand(cfg, state.profile, state.seen, state.level, state.lam_long, now_t, cfg.t)

    feasibility = if r_remaining > 0, do: lam_rem * state.beta_hat / r_remaining, else: :infinity

    %{
      cap: cap,
      r_remaining: r_remaining,
      lam_tot: lam_tot,
      t_rem: t_rem,
      p: throttle(rstar, lam_tot, state.beta_hat),
      feasibility: feasibility
    }
  end

  # Target spend rate r* in DB units (uniform or adaptive; ∞ inside the finish buffer).
  defp target_rate(state, r_remaining, lam_tot, t_rem, now_t, cfg) do
    t_plan = cfg.t - cfg.finish_buffer

    cond do
      t_rem <= 0 -> 0.0
      now_t >= t_plan -> :infinity
      cfg.strategy == :uniform -> r_remaining / ((t_plan - now_t) * (1.0 - cfg.forecast_haircut))
      true -> adaptive_rate(state, r_remaining, lam_tot, now_t, t_plan, cfg)
    end
  end

  defp adaptive_rate(state, r_remaining, lam_tot, now_t, t_plan, cfg) do
    lam_plan =
      (1.0 - cfg.forecast_haircut) *
        Model.remaining_demand(cfg, state.profile, state.seen, state.level, state.lam_long, now_t, t_plan)

    if lam_plan > 0, do: lam_tot * r_remaining / lam_plan, else: 0.0
  end

  # Throttle p = r* / (β̂ · Σλ̂). A huge finite number stands in for ∞.
  defp throttle(_rstar, lam_tot, _beta_hat) when lam_tot <= 0, do: 0.0
  defp throttle(:infinity, _lam_tot, _beta_hat), do: 1.0e18
  defp throttle(rstar, lam_tot, beta_hat), do: rstar / (beta_hat * lam_tot)

  # Feasibility alert: after day 1, expected demand cannot fill the remaining budget.
  defp update_alert(state, plan, tick, cfg) do
    now_t = tick * cfg.dt

    if now_t > @day and plan.r_remaining > cfg.alert_tol * cfg.b and plan.feasibility < 1.0 do
      {state.alert_first || now_t, state.alert_minutes + cfg.dt}
    else
      {state.alert_first, state.alert_minutes}
    end
  end

  # Grant duration in ticks: τ = clamp(tau_frac·(T−t), tau_min, tau_max).
  defp grant_ticks(t_rem, cfg) do
    tau = clamp(cfg.tau_frac * t_rem, cfg.tau_min, cfg.tau_max)
    max(1, round(tau / cfg.dt))
  end

  # --- Exposure ---

  # Latest tick index surely included in Y (now − D_max), capped by the report index.
  defp safe_index(tick, cfg) do
    d_max_ticks = ceil(Config.d_max(cfg) / cfg.dt)
    rep = max(0, tick - round(cfg.report_lag / cfg.dt))
    min(max(0, tick - d_max_ticks), rep)
  end

  defp compute_exposure(grants, unsettled, ccli_fn, tick, cfg) do
    s = safe_index(tick, cfg)

    {e, kept} =
      Enum.reduce(unsettled, {0.0, []}, fn idx, {e_acc, kept_acc} ->
        g = Enum.at(grants, idx)
        e = Model.exposure(g, ccli_fn, s, tick, cfg)

        if e > 0 do
          {e_acc + e, [idx | kept_acc]}
        else
          {e_acc, kept_acc}
        end
      end)

    {e, Enum.reverse(kept)}
  end

  # --- Grant issuance ---

  # Serve requests in `perm` order. `ctx` holds the per-tick inputs shared by all requests.
  # Returns the accumulator: grants, unsettled, e, issued, denied, issued_amount, expired_grants.
  defp issue_grants(perm, ctx, grants, unsettled, e_total) do
    initial_acc = %{
      grants: grants,
      unsettled: unsettled,
      e: e_total,
      issued: 0,
      denied: 0,
      issued_amount: 0.0,
      expired_grants: []
    }

    Enum.reduce(perm, initial_acc, fn client_idx, acc ->
      case Map.get(ctx.requesting_clients, client_idx) do
        nil -> acc
        req -> issue_one(client_idx, req.old_grant_idx, acc, ctx)
      end
    end)
  end

  # Size one grant, check the hard cap, then issue it or deny it.
  # client_idx is 1-based; ctx.lam is a 0-indexed list.
  defp issue_one(client_idx, old_idx, acc, ctx) do
    cfg = ctx.cfg
    client_lam = Enum.at(ctx.lam, client_idx - 1, 0.0)
    rate = min(ctx.p, 1.0 + cfg.demand_headroom) * client_lam
    expiry = min(ctx.tick + ctx.tau_st, ctx.n_ticks + 1)
    amount = rate * (expiry - ctx.tick) * cfg.dt

    {e_before, e_after, updated_grants} = switch_off_old(old_idx, acc.grants, ctx)

    headroom = (ctx.cap - ctx.y - (acc.e - e_before + e_after)) / cfg.beta_max
    g_amount = min(amount, headroom)

    if g_amount < cfg.min_grant do
      deny(acc, updated_grants, old_idx)
    else
      new_grant = %Grant{
        client: client_idx,
        amount: g_amount,
        rate: rate,
        lam_issue: client_lam,
        issue_tick: ctx.tick,
        expiry_tick: expiry
      }

      new_grants = updated_grants ++ [new_grant]

      %{
        acc
        | grants: new_grants,
          unsettled: acc.unsettled ++ [length(new_grants) - 1],
          e: acc.e + e_after - e_before + cfg.beta_max * g_amount,
          issued: acc.issued + 1,
          issued_amount: acc.issued_amount + g_amount,
          expired_grants: add_expired(old_idx, updated_grants, acc.expired_grants)
      }
    end
  end

  # Tentatively switch off the grant being replaced. Returns {e_before, e_after, grants}.
  defp switch_off_old(nil, grants, _ctx), do: {0.0, 0.0, grants}

  defp switch_off_old(old_idx, grants, ctx) do
    cfg = ctx.cfg
    old = Enum.at(grants, old_idx)
    e_before = Model.exposure(old, ctx.ccli_fn, ctx.s, ctx.tick, cfg)

    updated = %Grant{
      old
      | switch_tick: ctx.tick,
        release_tick: if(cfg.return_unused, do: ctx.tick, else: old.expiry_tick)
    }

    e_after = Model.exposure(updated, ctx.ccli_fn, ctx.s, ctx.tick, cfg)
    {e_before, e_after, List.replace_at(grants, old_idx, updated)}
  end

  # Deny: the client keeps using its old grant, so undo the tentative switch-off.
  defp deny(acc, updated_grants, nil), do: %{acc | grants: updated_grants, denied: acc.denied + 1}

  defp deny(acc, updated_grants, old_idx) do
    %Grant{} = old = Enum.at(acc.grants, old_idx)
    restored = List.replace_at(updated_grants, old_idx, %Grant{old | switch_tick: nil, release_tick: nil})
    %{acc | grants: restored, denied: acc.denied + 1}
  end

  defp add_expired(nil, _grants, expired), do: expired
  defp add_expired(old_idx, grants, expired), do: [Enum.at(grants, old_idx) | expired]

  defp extract_new_grants(grants, issued_count) do
    # The last `issued_count` grants are the newly issued ones
    if issued_count > 0 do
      Enum.slice(grants, (length(grants) - issued_count)..-1//1)
    else
      []
    end
  end

  defp clamp(val, lo, hi), do: max(lo, min(val, hi))
end

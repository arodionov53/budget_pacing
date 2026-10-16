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

  def tick(pid, tick_data) do
    GenServer.call(pid, {:tick, tick_data}, :infinity)
  end

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
  def handle_call({:tick, tick_data}, _from, state) do
    cfg = state.config
    dt = cfg.dt

    %{
      tick: tick,
      reports: reports,
      y_obs: y,
      ctot_aligned: ctot_aligned,
      ctot_rep: ctot_rep,
      s_db_now: s_db_now,
      ccli_fn: ccli_fn,
      requesting_clients: requesting_clients,
      perm: perm
    } = tick_data

    t = (tick - 1) * dt
    n_ticks = round(cfg.t / dt)

    # ======= estimation =======
    state = update_demand(state, cfg, reports, t, tick, dt)
    state = update_beta(state, cfg, y, ctot_aligned, dt)

    # nowcast
    s_hat =
      if cfg.nowcast == :none do
        y
      else
        y + state.beta_hat * (ctot_rep - ctot_aligned)
      end

    err_hat = state.err_hat + abs(s_hat - s_db_now)
    err_naive = state.err_naive + abs(y - s_db_now)

    # ======= pacing =======
    cap = cfg.b * (1.0 - cfg.delta)
    t_plan = cfg.t - cfg.finish_buffer
    r_remaining = max(cap - s_hat, 0.0)
    lam_tot = Enum.sum(state.lam)
    t_rem = cfg.t - tick * dt

    rstar =
      cond do
        t_rem <= 0 ->
          0.0

        tick * dt >= t_plan ->
          :infinity

        cfg.strategy == :uniform ->
          r_remaining / ((t_plan - tick * dt) * (1.0 - cfg.forecast_haircut))

        true ->
          # adaptive
          lam_plan =
            (1.0 - cfg.forecast_haircut) *
              Model.remaining_demand(
                cfg,
                state.profile,
                state.seen,
                state.level,
                state.lam_long,
                tick * dt,
                t_plan
              )

          if lam_plan > 0, do: lam_tot * r_remaining / lam_plan, else: 0.0
      end

    p =
      cond do
        lam_tot <= 0 -> 0.0
        rstar == :infinity -> 1.0e18
        true -> rstar / (state.beta_hat * lam_tot)
      end

    # feasibility
    lam_rem =
      Model.remaining_demand(
        cfg,
        state.profile,
        state.seen,
        state.level,
        state.lam_long,
        tick * dt,
        cfg.t
      )

    feasibility = if r_remaining > 0, do: lam_rem * state.beta_hat / r_remaining, else: :infinity

    {alert_first, alert_minutes} =
      if tick * dt > @day and r_remaining > cfg.alert_tol * cfg.b and feasibility < 1.0 do
        first = state.alert_first || tick * dt
        {first, state.alert_minutes + dt}
      else
        {state.alert_first, state.alert_minutes}
      end

    # ======= exposure =======
    {e_total, unsettled} = compute_exposure(state.grants, state.unsettled, ccli_fn, tick, cfg)

    # ======= grant issuance =======
    tau = clamp(cfg.tau_frac * t_rem, cfg.tau_min, cfg.tau_max)
    tau_st = max(1, round(tau / dt))

    {grants, unsettled, issued, denied, issued_amount, e_total, expired_grants} =
      issue_grants(
        perm,
        requesting_clients,
        state.grants,
        unsettled,
        e_total,
        p,
        tau_st,
        tick,
        n_ticks,
        y,
        cap,
        ccli_fn,
        state.lam,
        cfg
      )

    max_commit = (y + e_total) / cfg.b

    state = %{
      state
      | grants: grants,
        unsettled: unsettled,
        err_hat: err_hat,
        err_naive: err_naive,
        alert_first: alert_first,
        alert_minutes: alert_minutes
    }

    result = %{
      s_hat: s_hat,
      p: min(p, 1.0 + cfg.demand_headroom),
      rstar: min(p, 1.0 + cfg.demand_headroom) * lam_tot * state.beta_hat,
      beta_hat: state.beta_hat,
      e: e_total,
      feasibility: feasibility,
      issued: issued,
      denied: denied,
      issued_amount: issued_amount,
      max_commit: max_commit,
      expired_grants: expired_grants,
      grants_for_clients: extract_new_grants(grants, issued)
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # --- Estimation ---

  defp update_demand(state, cfg, reports, t, _tick, dt) do
    # reports: list of %{demand: d} per client (0-indexed by client_id - 1)
    demands = Enum.map(reports, & &1.demand)
    tot = Enum.sum(demands) / dt

    {lam, lam_long, initialized} =
      if not state.initialized do
        lam = Enum.map(demands, &(&1 / dt))
        {lam, tot, true}
      else
        alpha = dt / cfg.ewma_minutes
        lam =
          Enum.zip(state.lam, demands)
          |> Enum.map(fn {old, d} -> old + alpha * (d / dt - old) end)

        lam_long = state.lam_long + dt / @day * (tot - state.lam_long)
        {lam, lam_long, true}
      end

    # level factor
    b = Model.bin_of(cfg, t)

    level =
      if cfg.level_minutes > 0 and Enum.at(state.seen, b - 1) and
           Enum.at(state.profile, b - 1) > 0 do
        state.level +
          dt / cfg.level_minutes * (tot / Enum.at(state.profile, b - 1) - state.level)
      else
        state.level
      end

    # profile bin update
    {profile, seen, cur_bin, bin_acc, bin_cnt} =
      if b != state.cur_bin do
        {profile, seen} =
          if state.cur_bin != 0 and state.bin_cnt > 0 do
            p_idx = state.cur_bin - 1
            avg = state.bin_acc / state.bin_cnt

            new_val =
              if Enum.at(state.seen, p_idx) do
                (1.0 - cfg.profile_alpha) * Enum.at(state.profile, p_idx) +
                  cfg.profile_alpha * avg
              else
                avg
              end

            {List.replace_at(state.profile, p_idx, new_val),
             List.replace_at(state.seen, p_idx, true)}
          else
            {state.profile, state.seen}
          end

        {profile, seen, b, 0.0, 0}
      else
        {state.profile, state.seen, state.cur_bin, state.bin_acc, state.bin_cnt}
      end

    %{
      state
      | lam: lam,
        lam_long: lam_long,
        initialized: initialized,
        level: level,
        profile: profile,
        seen: seen,
        cur_bin: cur_bin,
        bin_acc: bin_acc + tot,
        bin_cnt: bin_cnt + 1
    }
  end

  defp update_beta(state, cfg, y, c_aligned, dt) do
    alpha = dt / cfg.beta_ewma_minutes
    ew_dy = state.ew_dy + alpha * ((y - state.prev_y) - state.ew_dy)
    ew_dc = state.ew_dc + alpha * ((c_aligned - state.prev_c) - state.ew_dc)

    beta_hat = if ew_dc > 1.0e-9, do: ew_dy / ew_dc, else: state.beta_hat

    %{state | ew_dy: ew_dy, ew_dc: ew_dc, prev_y: y, prev_c: c_aligned, beta_hat: beta_hat}
  end

  # --- Exposure ---

  defp compute_exposure(grants, unsettled, ccli_fn, tick, cfg) do
    d_max_ticks = ceil(Config.d_max(cfg) / cfg.dt)
    s = max(0, tick - d_max_ticks)
    rep = max(0, tick - round(cfg.report_lag / cfg.dt))
    s = min(s, rep)

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

  defp issue_grants(
         perm,
         requesting_clients,
         grants,
         unsettled,
         e_total,
         p,
         tau_st,
         tick,
         n_ticks,
         y,
         cap,
         ccli_fn,
         lam,
         cfg
       ) do
    dt = cfg.dt
    d_max_ticks = ceil(Config.d_max(cfg) / cfg.dt)
    s = max(0, tick - d_max_ticks)
    rep = max(0, tick - round(cfg.report_lag / cfg.dt))
    s = min(s, rep)

    initial_acc = %{
      grants: grants,
      unsettled: unsettled,
      e: e_total,
      issued: 0,
      denied: 0,
      issued_amount: 0.0,
      expired_grants: []
    }

    result =
      Enum.reduce(perm, initial_acc, fn client_idx, acc ->
        # client_idx is 0-based index into requesting_clients
        unless Map.get(requesting_clients, client_idx) do
          acc
        else
          i = client_idx
          # Use center's own updated lam (lam is 0-indexed list, client_idx is 1-based)
          client_lam = Enum.at(lam, client_idx - 1, 0.0)

          rate = min(p, 1.0 + cfg.demand_headroom) * client_lam
          expiry = min(tick + tau_st, n_ticks + 1)
          amount = rate * (expiry - tick) * dt

          # Handle old grant replacement
          old_grant_idx = requesting_clients[client_idx].old_grant_idx
          {e_before, e_after, updated_grants} =
            if old_grant_idx != nil do
              old = Enum.at(acc.grants, old_grant_idx)
              e_before = Model.exposure(old, ccli_fn, s, tick, cfg)

              updated =
                %Grant{
                  old
                  | switch_tick: tick,
                    release_tick: if(cfg.return_unused, do: tick, else: old.expiry_tick)
                }

              e_after = Model.exposure(updated, ccli_fn, s, tick, cfg)
              updated_grants = List.replace_at(acc.grants, old_grant_idx, updated)
              {e_before, e_after, updated_grants}
            else
              {0.0, 0.0, acc.grants}
            end

          headroom = (cap - y - (acc.e - e_before + e_after)) / cfg.beta_max
          g_amount = min(amount, headroom)

          if g_amount < cfg.min_grant do
            # Deny — restore old grant if we modified it
            restored_grants =
              if old_grant_idx != nil do
                %Grant{} = old = Enum.at(acc.grants, old_grant_idx)
                List.replace_at(updated_grants, old_grant_idx, %Grant{old | switch_tick: nil, release_tick: nil})
              else
                updated_grants
              end

            %{acc | grants: restored_grants, denied: acc.denied + 1}
          else
            new_grant = %Grant{
              client: i,
              amount: g_amount,
              rate: rate,
              lam_issue: client_lam,
              issue_tick: tick,
              expiry_tick: expiry
            }

            new_grants = updated_grants ++ [new_grant]
            new_idx = length(new_grants) - 1
            new_e = acc.e + e_after - e_before + cfg.beta_max * g_amount

            expired =
              if old_grant_idx != nil do
                [Enum.at(updated_grants, old_grant_idx) | acc.expired_grants]
              else
                acc.expired_grants
              end

            %{
              acc
              | grants: new_grants,
                unsettled: acc.unsettled ++ [new_idx],
                e: new_e,
                issued: acc.issued + 1,
                issued_amount: acc.issued_amount + g_amount,
                expired_grants: expired
            }
          end
        end
      end)

    {result.grants, result.unsettled, result.issued, result.denied, result.issued_amount,
     result.e, result.expired_grants}
  end

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

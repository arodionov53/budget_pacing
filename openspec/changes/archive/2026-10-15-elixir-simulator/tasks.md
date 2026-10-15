# Tasks

## 1. Project scaffold and config

- [x] 1.1 Create the Mix project at `elixir/` with `mix new budget_pacing_sim --sup`. Add `toml` and `jason` to `mix.exs` deps. Verify `mix deps.get && mix compile` succeeds with no warnings.
- [x] 1.2 Implement `BudgetPacingSim.Config` struct with all 37 parameters and their defaults matching `src/config.jl`. Implement `d_assumed/1` and `d_max/1` derived defaults. Verify by writing `config_test.exs` that asserts default values match the Julia ones (B = 1.0e6, T = 10080.0, dt = 1.0, n_clients = 50, demand_ratio = 1.5, etc.).
- [x] 1.3 Implement `Config.load!/1` that reads a TOML file, merges with defaults, and returns a `%Config{}`. Verify with a test that loads a partial TOML (only `B` and `n_clients` set) and asserts all other fields are defaults.
- [x] 1.4 Implement `Config.validate!/1` with the same checks as `src/config.jl`: strategy must be `:uniform` or `:adaptive`, exposure_mode must be `:reported` or `:full`, nowcast must be `:reports` or `:none`, and warning-level checks for beta_max, D_max, renew_lead. Verify with tests: invalid strategy raises, valid config passes, safety-warning config logs but does not raise.
- [x] 1.5 Create `priv/default_config.toml` with all parameters documented in comments, grouped into `[world]`, `[center]`, and `[policy]` sections. Verify `Config.load!("priv/default_config.toml")` returns a config identical to `Config.new()`.

## 2. Model pure functions and Grant struct

- [x] 2.1 Implement `BudgetPacingSim.Grant` struct with fields: client, amount, rate, lam_issue, issue_tick, expiry_tick, switch_tick (nil = in use), release_tick (nil = not yet). Verify struct creation in `model_test.exs`.
- [x] 2.2 Implement `BudgetPacingSim.Model.base_pattern/3` — daily sine × weekend reduction, matching `model.jl:base_pattern`. Verify with a test that checks: midnight gives minimum, noon gives maximum, weekend days are reduced by weekly_amp.
- [x] 2.3 Implement `Model.shock/2` — returns shock_factor inside the window, 1.0 outside. Verify with a test at t inside and outside the shock window.
- [x] 2.4 Implement `Model.exposure/5` — upper bound on unsettled DB spend from a grant, matching `model.jl:exposure`. Verify with tests for: grant in use (full remaining), grant returned (final − safe), grant settled (0), and `:full` exposure mode.
- [x] 2.5 Implement `Model.bin_of/2` and `Model.remaining_demand/4` — daily profile integration from t to T, matching `model.jl`. Verify `bin_of` maps t=0 to bin 1, t=DAY-1 to last bin. Verify `remaining_demand` with a uniform profile returns level × (T−t).

## 3. CentralDB GenServer

- [x] 3.1 Implement `BudgetPacingSim.CentralDB` GenServer with state holding `s_db` (list), `ccli` (map of id → list), `ctot` (list). `init/1` takes config, initializes all to `[0.0]`. Verify it starts and responds to a status call.
- [x] 3.2 Implement `handle_call({:record_spend, tick, spends}, ...)` where `spends` is a list of `{client_id, client_amount, db_amount}`. Appends to `s_db`, updates per-client `ccli` and `ctot`. Verify: after recording two ticks of spend, `s_db` has 3 entries (initial + 2) and cumulative sums are correct.
- [x] 3.3 Implement `handle_call({:observe, tick, d_jitter_ticks}, ...)` that returns `Y = s_db[max(1, tick − D_ticks − jitter)]` with monotonic guarantee (never returns a value older than previous call). Verify: with D=3 ticks, observation at tick 5 returns s_db[2]; consecutive calls never decrease.
- [x] 3.4 Implement `handle_call({:lookup, client_id, index}, ...)` returning `ccli[client_id][index]` and `handle_call({:ctot, index}, ...)` returning `ctot[index]`. Verify both return correct historical values.

## 4. Client GenServer

- [x] 4.1 Implement `BudgetPacingSim.Client` GenServer. `init/1` takes `{id, mu, phase, initial_logdrift, config}`. State is a `Client.State` struct. Verify it starts with correct initial state.
- [x] 4.2 Implement `handle_call({:tick, tick, randoms}, ...)` where `randoms` contains `{demand_noise, drift_noise}`. The client: (a) computes demand d using `Model.base_pattern`, shock, OU drift, and the provided noise; (b) updates `lam_own` EWMA; (c) spends via token bucket: min(d, tokens, amount_left); (d) handles partial return; (e) determines if a grant request is needed; (f) returns `{:ok, %{spend: spend, demand: d, cum_spend: cum_spend, request: bool}}`. Verify with a test: give a client a grant, send a tick with known randoms, assert spend ≤ demand, spend ≤ tokens, cum_spend updated.
- [x] 4.3 Implement `handle_call({:receive_grant, grant}, ...)` that installs a new grant, handles replacement of old grant (switch_tick, release_tick on old grant), resets `used` to 0, caps token carry-over. Verify: receiving a grant while holding one sets switch_tick on the old and activates the new.
- [x] 4.4 Implement grant expiry detection inside `:tick` — when `tick >= grant.expiry_tick`, stop spending and clear the grant. Verify: after expiry tick, client spend is 0 and grant is nil.

## 5. Center GenServer

- [x] 5.1 Implement `BudgetPacingSim.Center` GenServer. `init/1` takes config. State is the `Center.State` struct with empty grants, zero estimates, profile initialized to zeros. Verify startup.
- [x] 5.2 Implement demand estimation in `handle_call({:tick, tick, reports, y_obs, ctot_aligned, ctot_rep}, ...)`: update per-client λ̂ EWMA, long-run demand EWMA, daily profile bin, level factor, β̂, and nowcast Ŝ. Verify: after feeding 30 ticks of constant demand d, λ̂ converges toward d; after a bin boundary, the profile bin is updated.
- [x] 5.3 Implement the pacing law: compute R, r*, p for both `:uniform` and `:adaptive` strategies, including the finish-buffer and forecast-haircut. Verify: uniform r* = R/((1−hc)·(T_plan−t)) for a known R and t; adaptive p does not depend on time of day when profile is flat.
- [x] 5.4 Implement exposure accounting: iterate unsettled grants, compute E via `Model.exposure`, prune settled grants. Verify: a settled grant is removed from unsettled; E for an active grant equals beta_max × remaining amount.
- [x] 5.5 Implement grant issuance: for each requesting client (in permuted order from randoms), compute rate, amount, check hard-cap headroom, handle old-grant replacement, issue or deny. Return list of issued grants and denied count. Verify: when headroom is tight, grant amount is reduced; when below min_grant, grant is denied.
- [x] 5.6 Implement feasibility alert: after day 1, check if β̂·Λ(t,T) < R. Verify: with demand_ratio = 0.9 and t > 1 day, alert fires.

## 6. Clock GenServer and simulation orchestration

- [x] 6.1 Implement `BudgetPacingSim.Clock` GenServer. `init/1` takes config, seeds `:rand`, generates world (client sizes via lognormal, phases, initial OU states) matching `simulate.jl` lines 20–25. Verify: with seed=1 and n_clients=50, the generated μ values are positive and sum to demand_ratio × B/T.
- [x] 6.2 Implement `handle_cast(:run, state)` that starts the supervision tree: starts CentralDB, Center, Client.Supervisor with n_clients children, then runs the tick loop. Verify: calling run with T=10 ticks completes without error.
- [x] 6.3 Implement the per-tick loop body: (a) draw all randoms for this tick (demand noise × n, drift noise × n, beta noise × n, jitter); (b) call each client with `:tick`; (c) call CentralDB with `:record_spend`; (d) call Center with `:tick` passing reports, DB observation, and grant-request permutation; (e) deliver issued grants to clients; (f) accumulate metrics. Verify: run 100 ticks with default config, assert spend_ratio > 0, no crash.
- [x] 6.4 Implement summary metrics collection at end of run: spend_ratio, overspend, underspend, grants_per_min, utilization, est_err, naive_err, finish_early, alert_minutes. Return as a map. Verify: a full 10080-tick default run completes and spend_ratio is close to 1.0.
- [x] 6.5 Implement optional time-series recording (every `record_every` ticks): accumulate t, S, Y, Ŝ, E, demand, spend, p, beta_hat into a list of maps. Verify: with record_every=10, the time-series list has 1008 entries for a full run.

## 7. CLI and integration

- [x] 7.1 Implement `Mix.Tasks.Sim` that parses `--config` and `--seed` flags, loads config, runs the simulation, and prints JSON summary to stdout. Verify: `mix sim` with no flags runs with defaults and prints valid JSON.
- [x] 7.2 Add `--record path.csv` flag that writes the time-series to a CSV file. Verify: the CSV has the expected header row and 1008 data rows for a default run.
- [x] 7.3 Write `integration_test.exs`: run a full simulation with default config (seed=1), assert spend_ratio == 1.0 (within 1e-4), overspend == 0, grants_per_min ≈ 2.3–2.5, utilization ≈ 0.88–0.92. These ranges come from the Julia results in MODEL.md §5.
- [x] 7.4 Add a second integration test with `strategy: :uniform`, assert spend_ratio == 1.0 and that grants_per_min ≈ 2.5.

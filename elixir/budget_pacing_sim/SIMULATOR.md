# How the Elixir simulator works

This document explains the internal mechanics of the Elixir budget pacing simulator: what
happens during a run, how the processes communicate, and how the code maps to the model in
[MODEL.md](../../MODEL.md) and [PACING.md](../../PACING.md).

## 1. Overview

A simulation run is a single call to `Clock.run(config)`. It returns a summary map and an
optional time series. Nothing persists between runs — every run starts fresh processes,
executes a tick loop, collects results, and stops everything.

```
Clock.run(config)
  │
  ├── seed RNG
  ├── generate world (client sizes, phases, drift)
  ├── start CentralDB, Center, 50 × Client GenServers
  ├── run 10,080 ticks (one per simulated minute)
  ├── collect summary metrics
  ├── stop all GenServers
  └── return {summary, time_series}
```

## 2. Processes

Each logical actor is a separate GenServer with its own state. They communicate exclusively
through synchronous `GenServer.call`, never through shared memory.

### CentralDB (`central_db.ex`)

**State:** three append-only arrays (Erlang `:array`):
- `s_db` — cumulative true DB spend, one entry per tick
- `ccli` — per-client cumulative counted spend (map of client_id → array)
- `ctot` — cumulative total client-counted spend

**What it does:**
- **Records spend** → `CentralDB.record_spend/3`: each tick the Clock sends
  `{client_id, client_amount, db_amount}` tuples. The DB appends to all three arrays.
- **Serves delayed observations** → `CentralDB.observe/4`: when the Center asks for `Y`,
  the DB returns `s_db[now − D − jitter]` with a monotonic guarantee (never goes backwards).
- **Serves historical lookups** → `CentralDB.lookup/3` and `CentralDB.ctot/2`: the Center's
  exposure calculation needs `ccli[client, index]` at past indices, and β̂ estimation and
  nowcast need `ctot[index]`.

The DB has no logic — it is a timestamped ledger with a delay window.

### Client (`client.ex`)

**State:** `mu` (mean demand), `phase` (daily shift), `logdrift` (OU state), `grant`
(current Grant struct or nil), `tokens` (bucket level), `used` (spend on current grant),
`cum_spend`, `lam_own` (own demand EWMA), `request_tick`.

**Each tick** (called by Clock with pre-drawn random numbers):

1. **OU drift update.** `logdrift += −logdrift·dt/θ + σ·√(2dt/θ)·ξ`. This makes demand
   wander slowly over hours.

2. **Demand generation.** `d = max(0, m·dt + cv·m·√dt·ξ)` where
   `m = μ · pattern(t+φ) · shock(t) · exp(logdrift − σ²/2)`.
   The pattern is a daily sine × weekend reduction. The client never sees the budget or the
   strategy — only its own demand and grant.

3. **EWMA of own demand.** `lam_own += α·(d/dt − lam_own)`, window 30 min.

4. **Token-bucket spend.** Bucket fills at the grant rate, capped at `burst_minutes × rate`.
   Spend = `min(demand, tokens, grant_amount − used)`. The bucket prevents a client from
   dumping a whole grant at once.

5. **Grant expiry.** If `tick ≥ expiry_tick`, stop spending and clear the grant.

6. **Partial return.** If `return_unused` is on, keep at most
   `return_keep_factor × min(rate, lam_own) × time_remaining` and return the excess.
   Only the amount shrinks; the rate stays.

7. **Grant request decision.** Request a new grant if:
   - no active grant, or
   - fewer than `renew_lead` minutes of time or money left, or
   - own demand has risen more than `regrant_threshold` above the grant's issue-time estimate.

Returns `{spend, demand, cum_spend, request, expired_grant, returned}` to the Clock.

### Center (`center.ex`)

**State:** per-client demand estimates (`lam`), daily profile (96 bins), level factor,
β̂ estimate, nowcast accumulators, list of all grants, unsettled grant indices, error
accumulators.

**Each tick** (called by Clock with reports, DB observation, and requesting-client info):

1. **Demand estimation.** Update per-client λ̂ (EWMA, 30 min) and the long-run total
   demand (EWMA, 1 day) from client reports (received with 1-minute lag).

2. **Daily profile.** 96 bins of 15 minutes each. When the current bin changes, the
   previous bin's value is blended: `profile[b] = (1−α)·old + α·average`.

3. **Level factor.** EWMA (4 h) of `current_total_demand / profile[now]`. This catches
   effects the profile doesn't know about yet — like weekends.

4. **β̂ estimation.** `EWMA(ΔY) / EWMA(ΔC)` over 4 hours, where ΔY is the DB increment
   and ΔC is the aligned client-reported spend increment.

5. **Nowcast.** `Ŝ = Y + β̂ · (C_total_recent − C_total_delayed)`. This is a Smith-predictor
   structure: delayed truth + calibrated fast signal over the blind window.

6. **Pacing law.** Compute throttle `p`:
   - **Uniform:** `r* = R / ((1−hc)·(T_plan − t))`, then `p = r* / (β̂ · Σλ̂)`.
     Same speed all the time.
   - **Adaptive:** `r* = R · Λ_now / ((1−hc) · Λ(t, T_plan))`, where Λ integrates
     `level · profile` over the remaining period. Money is allocated in proportion to
     expected demand — the throttle stays roughly constant.
   - **Inside finish buffer** (last hour): `r* = ∞`, let the hard cap be the only limit.

7. **Exposure accounting.** For every unsettled grant, compute the upper bound on DB spend
   not yet included in Y: `e = β_max · (amount − used_safe)`. Prune settled grants.

8. **Grant issuance.** For each requesting client (in random order):
   - rate = `min(p, 1+headroom) · λ̂_i`
   - duration τ = `clamp(0.01·(T−t), 5, 60)` minutes
   - amount = rate × τ
   - **Hard-cap check:** issue only if `Y + E + β_max·amount ≤ B·(1−δ)`. Cut amount to fit,
     or deny if below `min_grant`.
   - If replacing an old grant: switch it off and free its unused exposure.

9. **Feasibility alert.** After day 1, fire if `β̂ · Λ(t,T) < R` — expected remaining
   demand can't fill the remaining budget.

Returns grants to issue, metrics, and the nowcast to the Clock.

### Clock (`clock.ex`)

Not a GenServer — a module with a recursive `run_ticks` loop. It orchestrates each tick:

1. **Draw all random numbers** for this tick centrally: demand noise (N per client), drift
   noise (N), beta noise (N), jitter. This ensures the random stream is consumed in a fixed
   order, making runs deterministic for a given seed.

2. **Tick all clients** sequentially with `GenServer.call`. Each client gets its pre-drawn
   randoms and returns a report.

3. **Record spend in DB.** Multiply each client's spend by `β_true · (1 + ε)` (the beta
   noise drawn in step 1) and send to CentralDB.

4. **Center tick.** Pass reports, DB observation Y, aligned counters, and requesting-client
   info. The Center updates estimates, computes the throttle, checks the hard cap, and
   returns grants to issue.

5. **Deliver grants** to clients via `GenServer.call`.

6. **Accumulate metrics** (total demand, total spend, issued/denied grants, time-series
   samples every `record_every` ticks).

## 3. The tick in pictures

```
              Clock (tick driver)
                │
    ┌───────────┼───────────┐
    ▼           ▼           ▼
 Client₁    Client₂  ... Client₅₀    ← Step 1: generate demand, spend, report
    │           │           │
    └───────────┼───────────┘
                │
                ▼
           CentralDB                   ← Step 2: record spend (β·(1+ε))
                │
                ▼
             Center                    ← Step 3: observe Y, estimate, pace, issue grants
                │
    ┌───────────┼───────────┐
    ▼           ▼           ▼
 Client₁    Client₂  ... Client₅₀    ← Step 4: receive grants
```

All arrows are synchronous `GenServer.call`. Tick N completes everywhere before tick N+1
begins. This is what makes the simulation deterministic despite running on multiple
processes.

## 4. World generation

Before the tick loop, `Clock.run` generates the world:

1. **Client sizes.** Draw `w_i = exp(0.8 · ξ)` for each client (lognormal). Normalize so
   they sum to 1. Scale to `μ_i = w_i · demand_ratio · B/T / norm`. This gives many small
   clients and a few large ones — the 5 largest hold ~28% of total demand.

2. **Phase shifts.** Each client gets a random daily phase shift (std 60 min), so peaks
   don't align perfectly.

3. **Initial OU state.** Drawn from the stationary distribution `N(0, σ²)` — no warm-up
   transient.

4. **Normalization.** The mean of `base_pattern(t, 0)` over all ticks ensures that the daily
   and weekly shapes don't change the total demand level.

## 5. RNG and determinism

A single `:rand` seed (Erlang's `exsss` algorithm) is set in the Clock at the start. All
random draws happen in the Clock in a fixed order per tick:

```
tick k: demand_noise[1..N], drift_noise[1..N], beta_noise[1..N], jitter
```

These are passed to the GenServers as arguments — no process draws its own randoms. This
guarantees that the same `seed + config` always produces the same results, despite the
multi-process architecture.

**Note:** The Julia simulator uses Xoshiro256++, so per-seed results differ between the two
simulators. Statistical properties (mean spend ratio, distribution shapes) are equivalent.

## 6. Data flow for key quantities

### How the center learns demand

```
Client demand d(t) ──[1 min lag]──→ Center λ̂_i (EWMA, 30 min)
                                       │
                                       ├──→ daily profile (96 bins, blended daily)
                                       ├──→ level factor (EWMA, 4 h: actual/profile)
                                       └──→ Σλ̂_i (total demand rate)
```

The client reports demand even while throttled, so the estimate is unbiased.

### How the center sees the budget

```
Client spend ──→ DB: S(t) = Σ β·(1+ε)·spend
                      │
                      ├──[delay D + jitter]──→ Y (what center observes)
                      │
Client reports ──→ β̂ = EWMA(ΔY)/EWMA(ΔC) ──→ Ŝ = Y + β̂·(C_recent − C_delayed)
                                                     (nowcast: 30× more accurate than Y)
```

### How a grant flows

```
Client: "I need a grant" (request_tick set)
    │
    ▼
Clock: includes client in requesting_clients map
    │
    ▼
Center: rate = min(p, 1.5) · λ̂_i
        amount = rate · τ
        check: Y + E + β_max·amount ≤ B  ← hard cap
        issue or deny
    │
    ▼
Clock: deliver grant to client
    │
    ▼
Client: install grant, reset used=0, start spending through token bucket
    │
    ├──→ partial return (if excess > threshold)
    ├──→ re-grant request (if demand > 1.3 × grant sizing)
    ├──→ renewal request (if < 3 min left)
    └──→ expiry (stop spending, free remainder)
```

## 7. The two safety mechanisms

### Hard-cap invariant (never overspend)

Uses no estimates — only bounds. For every open grant `k`:

```
e_k = β_max · (amount_k − used_safe_k)     if still in use
e_k = β_max · (used_final_k − used_safe_k)  if returned
e_k = 0                                      if settled (safe index past switch)
```

A new grant `g` is issued only if `Y + Σe_k + β_max·g ≤ B·(1−δ)`.

**Why it works:** future DB spend comes only from existing grants (bounded by E) and new
grants (checked when issued). When money is spent, Y grows by at most what E shrinks, so
`Y + E` never increases between issues.

### Pacing controller (avoid underspend)

Statistical — uses estimates, may be wrong, but that doesn't affect safety. It controls how
*fast* to spend, not the *limit*. The hard cap handles the limit independently.

## 8. Module map

```
lib/budget_pacing_sim/
├── config.ex       37 parameters, TOML loading, validation, Config.with/2
├── grant.ex        Grant struct (amount, rate, expiry, switch/release)
├── model.ex        Pure functions: base_pattern, shock, exposure, bin_of, remaining_demand
├── client.ex       Client GenServer: demand, token bucket, grant lifecycle
├── center.ex       Center GenServer: estimation, pacing, hard cap, grants
├── central_db.ex   CentralDB GenServer: spend ledger, delayed observations
├── clock.ex        Orchestrator: world gen, RNG, tick loop, metrics
└── analysis.ex     run_mc, aggregate, format_table, write_csv

lib/mix/tasks/
├── sim.ex          mix sim — single run
├── sim_sweep.ex    mix sim.sweep — Monte Carlo over 27 scenarios
└── sim_compare.ex  mix sim.compare — 3 strategies side by side
```

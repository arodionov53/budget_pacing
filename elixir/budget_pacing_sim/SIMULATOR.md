# How the Elixir simulator works

This document explains the internal mechanics of the Elixir budget pacing simulator: what
happens during a run, how the processes communicate, and how the code maps to the model in
[MODEL.md](../../MODEL.md) and [PACING.md](../../PACING.md).

## 0. The problem

This is the problem the simulator models, repeated from [MODEL.md §1](../../MODEL.md).

A **center** must spend a budget B during a period T.

- B is a **hard cap**: the true spend must never exceed it. Underspend is undesirable but allowed.
- Spending is done by **clients**. A client may spend only from a live **grant** issued by the
  center. A grant is a small local budget with a pacing rate and an expiry time.
- Client demand is random: a mean rate with Gaussian noise, and daily and weekly patterns
  **that are not known in advance**. Total demand is usually, but not always, larger than B/T.
- The authoritative spend comes from a **central database**. It is visible only after a delay
  D, and it is **not** the sum of what clients count (fees, rounding, currency effects and so
  on).
- Clients send fast but non-authoritative usage reports, and they can return unused grant
  amounts early.

The design problem: choose grant sizes, rates and expiries so that the budget is spent as fully
and smoothly as possible, without ever exceeding B, while the true state is only seen with a
delay.

In the simulator, each of these actors is a separate process: the Center, one Client process
per client, and the CentralDB. A fourth process-like module, the Clock, drives simulated time.

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

## Key symbols

These symbols appear throughout this document and the code. Full definitions are in
[MODEL.md §2](../../MODEL.md).

| Symbol | Meaning |
|---|---|
| **B** | Total budget (hard cap). Default 1,000,000. |
| **T** | Period length in minutes. Default 10,080 (7 days). |
| **S(t)** | True cumulative spend in the DB at time t. |
| **Y** | The delayed DB observation the center sees: `Y = S(t − D − jitter)`. The center never sees S directly — Y is always D minutes behind, plus random jitter. This is the only authoritative spend number the center has. |
| **C(t)** | Total client-counted spend up to time t, summed over all clients (the `ctot` array in CentralDB). Clients report it with a 1-minute lag, so the center sees it almost in real time, but it is in client units, not DB units. |
| **C_recent** | `C(t − report_lag)`: the latest total the center has from client reports. In code, `ctot_rep`. |
| **C_delayed** | `C(t − D_assumed)`: the total at the time Y refers to (`D_assumed` defaults to D). In code, `ctot_aligned`. |
| **Ŝ** | The center's nowcast (estimate of the true S): `Ŝ = Y + β̂ · (C_recent − C_delayed)`. Y is the true spend up to D minutes ago; `C_recent − C_delayed` is what clients reported spending since then, converted to DB units by β̂. Combines the stale-but-true Y with the fast-but-approximate client reports. |
| **D** | DB observation delay in minutes. Default 30. |
| **D_assumed** | The delay the center *believes* Y has, used for estimation. A config parameter (`d_assumed`), not estimated from data; defaults to D. See [D_assumed and D_max](#d_assumed-and-d_max). |
| **D_max** | Upper bound on the delay, used only by the hard cap. Defaults to `D + D_jitter`. |
| **E** | Exposure: upper bound on DB spend from open grants not yet reflected in Y. |
| **β** | DB amount per client-counted unit (`ΔS ≈ β · ΔC`). True value `beta_true` = 1.02; center's estimate `β̂`; safety bound `beta_max` = 1.06. |
| **R** | Remaining budget: `R = B·(1 − δ) − Ŝ`, never below 0. `δ` is an optional safety margin, 0 by default. |
| **r\*** | Target spend rate: how much the center wants spent per minute right now, in DB units. Computed from R by the pacing law (uniform or adaptive, see Center step 6); ∞ inside the finish buffer. |
| **p** | Throttle: the fraction of demand clients are allowed to serve. `p = r* / (β̂ · Σλ̂)`. |
| **λ̂_i** | Center's EWMA estimate of client i's demand rate. |

### D_assumed and D_max

The center never measures the DB delay; it is told it through two config parameters.

**`D_assumed`** is not calculated or estimated from data. It is set in config, and when unset
(the default) it takes the value of the true delay D, so by default the center knows the
delay exactly:

```elixir
# config.ex
d_assumed: nil,   # delay used for estimation (nil → d_delay)

def d_assumed(%__MODULE__{d_assumed: nil, d_delay: d}), do: d
def d_assumed(%__MODULE__{d_assumed: val}), do: val
```

This matches Julia's `d_assumed(cfg) = isnan(cfg.D_assumed) ? cfg.D : cfg.D_assumed`. To model
a center that has the delay wrong, set it in the TOML `[center]` section (`d_assumed = 45.0`).

It is used in one place, `Clock.observe_db`, to pick which past value of `C(t)` lines up with
Y:

```elixir
rep_idx = max(0, now - round(cfg.report_lag / dt))                       # → C_recent
a_est   = max(0, min(now - round(Config.d_assumed(cfg) / dt), rep_idx))  # → C_delayed
```

`C_delayed = C(now − D_assumed)` feeds two estimates:

- **β̂** = EWMA(ΔY) / EWMA(ΔC_delayed). This works only if ΔY and ΔC_delayed cover the same
  minutes.
- **Nowcast** Ŝ = Y + β̂ · (C_recent − C_delayed). The window `C_recent − C_delayed` is meant to
  cover exactly the spend that Y doesn't include yet.

If `D_assumed` is wrong:

- **Shorter than D:** the window misses part of the spend Y hasn't caught up with, so Ŝ is too
  low.
- **Longer than D:** spend already counted in Y is added again, so Ŝ is too high.

Either way only pacing suffers (spending too early or too late), and β̂ gets a little noisier
because ΔY and ΔC_delayed no longer line up.

**`D_max`** (`d_max`, default `D + D_jitter`) is a different thing: the upper bound the hard cap
relies on to decide which spend is surely included in Y.

| | `D_assumed` | `D_max` |
|---|---|---|
| Used by | β̂ and the nowcast (pacing) | the hard cap (exposure) |
| Kind of value | best guess | conservative bound |
| Default | `D` | `D + D_jitter` |
| If wrong | pacing spends too early or too late | too small: the budget can be overspent (MODEL.md §6.G) |

**Jitter quirk.** Y is delayed by `D + jitter`, with jitter uniform in `[0, D_jitter]`, but
`D_assumed` still defaults to `D`. With jitter on, the nowcast window is therefore on average
`D_jitter / 2` too short. Julia has the same default.

### EWMA

**EWMA** (exponentially weighted moving average) is the running average used for every
smoothed estimate here: λ̂_i, `lam_own`, β̂ and the level factor. Each new value moves the
estimate a fraction `α = dt / window` of the way toward it. The definition, and what the
window means, are in [MODEL.md §2](../../MODEL.md).

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

   See [How a client decides to request a grant](#how-a-client-decides-to-request-a-grant)
   for the details.

Returns `{spend, demand, cum_spend, request, expired_grant, returned}` to the Clock.

#### How a client decides to request a grant

The decision runs at the end of every client tick, in `request_decision/6` and
`needs_renewal?/5` (`client.ex`). It uses only what the client knows: its current grant, how
much of it is spent (`used`), its own demand estimate `lam_own`, and the current tick. The
client never sees the budget, the throttle `p`, or other clients.

**State.** `request_tick` holds the tick at which the open request was sent, or `nil` if
there is none. A client has **at most one open request**.

**The decision**, in order:

| # | Situation | Decision | Why |
|---|---|---|---|
| 1 | A request is already open (`request_tick != nil`) | Do nothing; keep `request_tick` | No duplicate requests |
| 2 | No grant (never had one, or it expired this tick) | Request | The client can't spend without a grant |
| 3 | Time left `(expiry_tick − tick)·dt ≤ renew_lead` | Request (**renewal**) | The grant is about to expire |
| 4 | Money left `amount − used ≤ rate · renew_lead` | Request (**renewal**) | The money runs out within `renew_lead` minutes at the grant rate |
| 5 | `lam_own / lam_issue > 1 + regrant_threshold` | Request (**re-grant**) | Demand has outgrown the grant |
| 6 | None of the above | Do nothing | The grant is still adequate |

Defaults: `renew_lead` = 3 min, `regrant_threshold` = 0.3. Conditions 3 and 4 have one
purpose: get the next grant in time. Condition 4 matters when the client spends faster than
expected, so the money runs out before the grant expires.

**Why re-grant (condition 5).** A grant's rate is fixed when it's issued:
`rate = min(p, 1.5) · λ̂_i`. `lam_issue` stores the demand the grant was sized for. If the
client's demand later jumps (because of the OU drift or the daily pattern), the token bucket
still only refills at the old rate, so the client would stay throttled until the grant
expires — up to 60 min. The re-grant asks for a new grant sized for the current demand. It
compares the **smoothed** demand `lam_own` (EWMA, 30 min), not the per-minute value, so
ordinary per-minute noise doesn't trigger it. MODEL.md §6.D shows this is the most important
client behaviour: without it, the worst run spends only 86 % of B.

**What the client does *not* request on.** A *drop* in demand never triggers a request.
That case is handled by partial return (step 6), which shrinks the amount and keeps the rate.
MODEL.md §6.D explains why: shrinking the rate instead lowered total spend.

**What happens next.**

1. The client sets `request_tick` and sends `request: true` in its report.
2. Once `grant_latency` has passed (one tick by default), the Clock puts the client into
   `requesting_clients` and the Center serves the requests in random order
   (`Center.issue_grants`).
3. If granted, `Client.receive_grant/3` installs the new grant. If the client already held
   one, the old grant is switched off and its unused part is freed at once. `used` resets to
   0 and `request_tick` resets to `nil`, so the client can request again later.
4. If the hard cap leaves less than `min_grant` of headroom, the request is denied, and
   `deny` puts the old grant back as it was. The request stays open and is retried on the
   next tick.

**Latency and retries.** These match `simulate.jl`:

- **`grant_latency`.** A request is served only once `grant_latency` (default 1 min) has
  passed since it was made, so a grant arrives one tick after the request at the earliest.
  This is why `renew_lead` must be larger than `grant_latency`: otherwise the old grant runs
  out before the new one arrives, and `Config.validate!/1` warns about it.
- **Denied requests are retried.** A denial leaves the request open (`request_tick` stays
  set). The Clock offers the client to the Center again every tick until a grant arrives,
  so the client gets a grant as soon as the hard cap frees enough headroom. Meanwhile it
  keeps spending from its old grant, if it has one.
- **Nothing is served on the last tick.** No grant can be used after `T`, so the Clock
  sends no requests to the Center on the final tick.

The Clock picks the requests to serve in `requesting_clients/4`, using the `request_tick`
that each client reports.

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

4. **β̂ estimation.** `EWMA(ΔY) / EWMA(ΔC_delayed)` over 4 hours, where ΔY is the
   per-tick change in Y and ΔC_delayed the per-tick change in C_delayed. Both refer to the
   same moment (D minutes ago), so their ratio is the DB amount per client-counted unit.

5. **Nowcast.** `Ŝ = Y + β̂ · (C_recent − C_delayed)`. This is a Smith-predictor
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
Client reports ──→ β̂ = EWMA(ΔY)/EWMA(ΔC_delayed) ──→ Ŝ = Y + β̂·(C_recent − C_delayed)
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

### How the center uses `Model` to create grants

The center uses three functions from `Model` (`model.ex`). Two of them decide **how fast** a
grant lets a client spend (the pacing side), and one decides **how big** a grant is allowed
to be (the hard cap):

| `Model` function | Where in `center.ex` | What it's used for |
|---|---|---|
| `bin_of/2` | `update_demand` | Learning the daily demand profile |
| `remaining_demand/7` | `adaptive_rate`, `plan` | Throttle `p`, and the feasibility alert |
| `exposure/5` | `compute_exposure`, `switch_off_old` | Hard-cap headroom |

The center never calls `Model.base_pattern` or `Model.shock`. Those generate the "true"
demand and only the Client uses them. The center only sees the client reports and the
delayed DB value, so it has to learn the demand pattern on its own.

**Step 1: Learn demand (`bin_of`).** Every tick, `update_demand` gets the reported demand of
all clients. `Model.bin_of(cfg, t)` says which 15-minute slot of the day the current time
falls in (one of 96). The center adds the total demand to that slot. When a new slot starts,
it blends the finished slot's average into `profile[slot]`. It also keeps a **level** factor:
actual demand divided by `profile[slot]`. The level catches changes the profile hasn't
learned yet, such as the weekend.

**Step 2: Choose the throttle (`remaining_demand`).**
`Model.remaining_demand(cfg, profile, seen, level, lam_long, t, t_end)` adds up
`level × profile` over the 15-minute slots from now until `t_end`. The result is the
**expected demand for the rest of the period**. For slots the center hasn't seen yet, it uses
the long-run average `lam_long`.

The adaptive strategy uses it in `adaptive_rate`:

```
r* = Σλ̂ · R / ((1 − haircut) · remaining_demand(now, T − buffer))
p  = r* / (β̂ · Σλ̂)          →  effectively  R / (β̂ · (1 − haircut) · expected demand)
```

Here `R = B − Ŝ` is the remaining budget. Since `Σλ̂` cancels out, the throttle is **the
share of expected future demand that the remaining budget can pay for**. That is why `p`
stays almost constant through the day. The uniform strategy doesn't call `remaining_demand`
at all; it divides `R` by the time left.

`plan` calls the same function again, up to `T`, for the feasibility alert: if
`β̂ × remaining_demand < R`, the expected demand can't use up the budget.

**Step 3: Size the grant (no `Model` call).** `issue_one` turns the throttle into a grant
for client `i`:

```
rate   = min(p, 1 + demand_headroom) · λ̂_i       # never more than 1.5× the client's demand
τ      = clamp(0.01 · (T − t), 5, 60) minutes    # grant_ticks/2
amount = rate · τ
```

**Step 4: Check the hard cap (`exposure`).** `Model.exposure(grant, ccli_fn, s, tick, cfg)`
gives an **upper bound on the DB spend a grant can still add on top of Y**. `s` is the latest
tick that is surely already included in Y (now minus `D_max`).

- **Grant still in use:** `β_max · (amount − spent up to s)`
- **Grant returned or expired:** `β_max · (actually spent − spent up to s)`
- **Settled:** `0`

It is used in two places:

1. `compute_exposure` adds it up over all open grants to get `E`, and removes the grants that
   are settled.
2. `switch_off_old` calls it twice when a client replaces its grant: once before switching
   the old grant off and once after. Switching off frees the old grant's unused part right
   away, so `E` goes down by `e_before − e_after`.

Then the cap check:

```
headroom = (B·(1−δ) − Y − (E − e_before + e_after)) / β_max
granted  = min(amount, headroom)
```

If `granted < min_grant`, the request is denied and `deny` switches the old grant back on.
Otherwise the grant is issued and `E` grows by `β_max · granted`.

**Why it's split this way.** `remaining_demand` and `bin_of` feed the **pacing controller**.
It uses estimates and can be wrong; when it is, the budget is spent too early or not fully.
`exposure` feeds the **hard cap**, which uses only bounds (`β_max`, `D_max`) and no
estimates. As long as those bounds hold, a wrong forecast can't cause overspend: the pacing
step sets `amount`, and the cap can only make it smaller. Section 7 explains why the cap
holds.

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

## 8. Parameters and their effect on results

All parameters live in `%Config{}` (`config.ex`) and in the TOML file
(`priv/default_config.toml`). Names are the Elixir/TOML names.

**Where the effects come from.** Unless stated otherwise, the effects are measured results
from the Julia simulator: the Monte Carlo sweep `scripts/sweep.jl` (40 seeds per scenario,
output in `../../out/sweep.txt`) and the tables in [MODEL.md §6](../../MODEL.md). The Elixir
simulator was run on the same 27 scenarios with `mix sim.sweep --runs 10` and agrees with
Julia in every scenario (see [ELIXIR_VS_JULIA.md](ELIXIR_VS_JULIA.md)). **Not measured**
means the parameter was never varied in those experiments, and the effect described is only
what the code implies.

**Result metrics** used in the table:

| Metric | Meaning |
|---|---|
| spend | Final true spend S(T) as % of B. The main result: 100 % is ideal, more than 100 % is overspend. |
| grants/min | Grants issued per minute: the load on the center. |
| util | Client spend / amount granted. Low util means grants reserve money that goes unused. |
| Ŝ err, Y err | Mean error of the nowcast and of the raw delayed Y, in ‰ of B. |
| idle tail | How long before T the budget reached 99.9 % of B (`finish_early`). A large value means the budget ran out early. |
| alert | Whether the feasibility alert fired. |

Baseline (all defaults, Julia): spend 100.000 %, 2.38 grants/min, util 89.9 %, Ŝ err 0.099 ‰,
Y err 2.976 ‰, idle tail 2.6 h, no alerts.

### Budget and horizon

| Parameter | Default | Effect on results |
|---|---|---|
| `b` | 1,000,000 | Scale only. Results are reported as fractions of B; `min_grant` (in money units) becomes relatively larger for small B. |
| `t` | 10,080 (7 days) | The period always starts Monday 00:00. With the default 7 days it ends on a low-demand Sunday night, which is the hardest case for pacing. A shorter T changes which days are included. Run time grows linearly with T. |
| `dt` | 1.0 min | Simulation step. **Not measured**; every EWMA window and delay is converted to ticks with it. |

### World: client demand

| Parameter | Default | Effect on results |
|---|---|---|
| `n_clients` | 50 | With fewer clients each grant is a larger share of B, so the hard cap has to hold more back near the end. 5 volatile clients with τ = 240: worst run 99.98 % (with return) vs 98.67 % (without). Run time grows linearly with it. |
| `demand_ratio` | 1.5 | **The biggest effect.** Below 1 the budget cannot be spent: 0.9 → 92.0 % spent, the alert fires in every run. 1.15 → still 100 %, util drops to 86.8 %. |
| `size_spread` | 0.8 | Lognormal spread of client sizes: with 0.8 the 5 largest clients hold 28 % of demand. Larger values concentrate demand in a few clients, with the same effect as a small `n_clients`. **Not measured.** |
| `noise_cv` | 0.5 | Per-minute noise. 1.5 → still 100 % and no overspend; util falls to 83.9 % and grants/min rises to 2.49. |
| `daily_amp` | 0.6 | Size of the daily cycle (4× between trough and peak at 0.6). The reason adaptive beats uniform pacing: uniform has to fight it. **Not measured** separately. |
| `daily_phase_jitter` | 60 min | Spreads client peaks apart. **Not measured.** |
| `weekly_amp` | 0.3 | Weekend demand drop. The profile is learned on weekdays, so this is what the level factor has to catch. Without the level factor, a late demand drop costs 1.8 points of spend (MODEL.md §6.A). |
| `drift_sigma`, `drift_tau` | 0.15, 360 min | Slow (hours-long) changes in each client's demand. The "volatile" setting (0.8, 120 min) is what makes re-grant matter: with τ = 240 and no re-grant, spend falls to 95.7 % (worst run 93.3 %). With re-grant: 100 %. |
| `shock_start`, `shock_length`, `shock_factor` | none | Unforeseen demand drop. Day-4 at 20 %: still 100 % (adaptive), 99.72 % (uniform). Last 12 h at 30 %: 99.14 %, the hardest test; spend lost late can't be recovered. |

### World: central DB

| Parameter | Default | Effect on results |
|---|---|---|
| `d_delay` | 30 min | The true DB delay D. With the nowcast, almost no effect: D = 120 → 99.998 %, Ŝ err still 0.10 ‰, while Y err grows to 11.9 ‰. Without the nowcast it is a hidden planning margin; see `nowcast`. |
| `d_jitter` | 0 | Random extra delay. 15 min → still 100 %, but Ŝ err rises from 0.099 to 0.475 ‰ (see the jitter quirk under D_assumed). Safe only if `d_max` covers it. |
| `beta_true` | 1.02 | The true DB/client ratio. Its **level doesn't matter**: 0.8 to 1.5 all give 100 %, because the center learns β̂ exactly (MODEL.md §6.H). Only `beta_max` has to cover it. |
| `beta_noise` | 0.01 | Per-transaction noise of that ratio. 0 to 10 % → 100 %; 30 % → 99.997 %. Its real cost is the wider `beta_max` it needs. |
| `report_lag` | 1 min | Delay of client reports. Sets how fresh `C_recent` is. **Not measured.** |

### Center assumptions (safety)

These are the only parameters that can make the budget be **overspent**.

| Parameter | Default | Effect on results |
|---|---|---|
| `beta_max` | 1.06 | Bound on β used by the hard cap. **Must be ≥ `beta_true`·(1 + 3·`beta_noise`)**, or the cap breaks in almost every run: true β = 1.08 with `beta_max` 1.06 → over B in 40/40 runs. Too large costs almost nothing: 2× the true β costs < 0.01 % of B. Err high. |
| `d_max` | `D + D_jitter` | Bound on the delay used by the hard cap. **Must be ≥ the true maximum delay**: D = 30 ± 15 with `d_max` = 30 → over B in 40/40 runs (by 0.1 ‰). Too large only holds money back near the end. |
| `d_assumed` | D | The delay used for estimation; affects pacing only, never safety. See [D_assumed and D_max](#d_assumed-and-d_max). **Not measured.** |
| `delta` | 0 | Extra safety margin: the center plans to spend at most B·(1 − δ). Lowers spend by about δ. |
| `exposure_mode` | `reported` | `full` ignores client counters and reserves every grant in full. Safe even if counters are wrong; costs 0.05–0.3 % of B at the end. |
| `return_unused` | true | Lets a replaced grant free its unused part at once. Matters when the cap binds and grants are large: 5 volatile clients, τ = 240, no return → 99.74 % (worst 98.67 %). With many small clients, no effect. |
| `regrant_threshold` | 0.3 | Re-grant when demand rises more than this. **The most important client setting** for volatile demand: disabling it (very large value) → 95.7 % with volatile clients. No effect with default (calm) demand. |
| `return_keep_factor` | 2.0 | Partial return. Small effect: 5 volatile clients, worst run 99.89 % → 99.98 % with it. 0 disables it. |

### Policy: pacing

| Parameter | Default | Effect on results |
|---|---|---|
| `strategy` | `adaptive` | `uniform` fights the daily cycle. It reaches 100 % in the baseline thanks to the margin, but loses in harder cases: last-12h shock 97.7 % vs 99.1 %, demand 0.9 → 87.6 % vs 92.0 %. Util 83.4 % vs 89.9 %. |
| `level_minutes` | 240 min | Level factor window; **0 disables it**. Matters when demand drops late: last-12h shock 97.4 % without vs 99.1 % with. No effect on the baseline. |
| `forecast_haircut` | 0.2 | Planned pessimism; **the main business trade-off**. Larger haircut: safer against late drops, but finishes earlier. 0.05 → idle tail 1.7 h, but last-12h shock 96.9 %. 0.2 → 2.6 h, 99.1 %. 0.3 → 3.6 h, 99.99 %. |
| `finish_buffer` | 60 min | Plan to finish this early; inside it, serve all demand. Blunt: 6 h buffer → 6.2 h idle tail. No buffer and no haircut → 99.997 % (baseline) and 95.8 % (last-12h shock). |
| `nowcast` | `reports` | `none` paces on the raw delayed Y. Spend is the same or slightly higher, because a stale Y makes the center think it's behind; but that margin grows with D (idle tail 3.7 h at D = 30, 9.7 h at D = 240). Keep `reports` and set the margin explicitly. |
| `demand_headroom` | 0.5 | Grants may serve up to (1 + h) × demand. h = 0.2 with 2-min bucket → still 100 %, util 89.5 %. Caps the throttle at 1 + h. |
| `ewma_minutes` | 30 min | Smoothing of the per-client demand estimate (and the client's own `lam_own`). Shorter reacts faster but is noisier. **Not measured.** |
| `beta_ewma_minutes` | 240 min | Smoothing of β̂. **Not measured**; β̂ ends exactly at the true β by the end of a default run. |
| `profile_bins` | 96 | Profile resolution (15-min bins). **Not measured.** |
| `profile_alpha` | 0.5 | Weight of the newest day in the profile. **Not measured.** |

### Policy: grants

| Parameter | Default | Effect on results |
|---|---|---|
| `tau_max` | 60 min | Longest grant. Sets center load, not total spend. 15 → 4.56 grants/min (vs 2.38), util 82.9 %. 240 → 2.30 grants/min. |
| `tau_min` | 5 min | Shortest grant (near the end). Setting `tau_min` = `tau_max` = 240 (fixed long grants): idle tail 5.1 h, util 70.5 %; with volatile clients util 33.6 %. |
| `tau_frac` | 0.01 | τ = clamp(`tau_frac`·(T − t), `tau_min`, `tau_max`), so grants shrink as T approaches. **Not measured** separately. |
| `renew_lead` | 3 min | Ask for the next grant this long before the current one runs out. **Must be > `grant_latency`**, or clients sit idle between grants (`Config.validate!/1` warns). **Not measured.** |
| `grant_latency` | 1 min | Time from request to grant. **Not measured.** |
| `burst_minutes` | 5 min | Token-bucket size. Smaller is smoother but captures less of noisy demand. With h = 0.2: 2 min still gives 100 %. |
| `min_grant` | 1.0 | Smaller grants aren't issued. Near the end it decides how much headroom is left unused. **Not measured.** |
| `alert_tol` | 0.001 | Alert ignores a remaining budget below this share of B. Affects only the alert, never spend. |

### Run

| Parameter | Default | Effect on results |
|---|---|---|
| `seed` | 1 | Which random world is drawn. Spend varies very little between seeds in the baseline (all 40 Julia runs 100.000 %), but more in hard scenarios (volatile, no re-grant: 93.3–99.1 %). Compare settings across several seeds (`mix sim.sweep`). |
| `record_every` | 10 | Time-series sampling only; no effect on results. 0 disables recording. |

### In short

- **Safety:** only `beta_max` and `d_max` can cause overspend. Set them generously; a value
  that is too large costs almost nothing.
- **Can the budget be spent at all?** `demand_ratio`, and late demand drops (`shock_*`,
  `weekly_amp`).
- **Main trade-off:** `forecast_haircut` and `finish_buffer`: protection against late demand
  drops, paid for with an earlier finish.
- **Strategy:** `strategy` and `level_minutes`. Adaptive with the level factor is best or tied
  in every tested case.
- **Center load:** `tau_max` and `tau_min`.
- **Volatile clients:** `regrant_threshold` and `return_unused`.

## 9. Module map

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

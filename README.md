# Budget pacing simulator (Julia)

A center must spend budget **B** during period **T** (hard cap: never more than B).
It hands out **grants** (local amount + pacing rate + expiry) to clients whose demand
is random (mean rate with Gaussian noise, unknown daily/weekly pattern, slow drift).
The only authoritative spend number comes from a central **DB, delayed by D**, and it
is *not* the sum of client-counted spend (ratio β, e.g. fees).

Full model description, strategy comparison and results: **[MODEL.md](MODEL.md)**.
How clients and the center work under each pacing strategy: **[PACING.md](PACING.md)**.

## Run

```sh
julia scripts/run.jl                          # one run → out/run.csv + summary
julia -t auto scripts/sweep.jl 40             # Monte Carlo over scenarios → table
julia --project=plots plots/plot.jl           # out/run.csv → out/run.png  (first time: Pkg.instantiate)
julia scripts/compare_pacing.jl               # strategies side by side → out/pacing_*.csv
julia --project=plots plots/plot_pacing.jl    # → out/pacing.png
```

The core has no dependencies (stdlib only). Change parameters with `Config(; ...)` or
`with(cfg; field = value)`; all parameters are documented in `src/config.jl`.

## What is simulated

| Part | Model |
|---|---|
| Client demand | `μᵢ · daily(t) · weekly(t) · drift(t) · dt + N(0, (cv·mean)²·dt)`, clipped at 0. Patterns are unknown to the center. Optional demand shock window. |
| Client spending | Token bucket at the grant rate (burst = `burst_minutes`) → never spends a grant immediately, even with demand. Stops at expiry or when the amount is used. |
| DB | Each client-step spend is recorded as `spend · β_true · (1 + noise)`; visible with delay `D + U(0, D_jitter)`. |
| Client reports | Cumulative client-counted spend and demand, lag `report_lag`. Fast but not authoritative. |

## Center design

**1. Hard-cap invariant (no model, no estimates).** A grant is issued only if

    Y + E + β_max · g ≤ B·(1 − δ)

where `Y` is the delayed DB value and `E` = Σ over unsettled grants of `β_max ·` (what the
grant can still add to the DB beyond `Y`). For a grant still in use that is
`amount − used(now − D_max)`; for a returned/expired grant `used_final − used(now − D_max)`.
`Y + E` can only decrease between issues, so the final DB spend cannot exceed the cap —
as long as `D ≤ D_max` and `β ≤ β_max` really hold (the sweep shows what happens when not).

**2. Nowcast (Smith-predictor style).** `Ŝ = Y + β̂ · (client-reported spend in the last D)`,
with `β̂` = EWMA of ΔY / Δ(reported, aligned by D). ~30× more accurate than `Y` alone.

**3. Pacing.** Remaining budget `R = B − Ŝ` is spread over the remaining *expected demand*:
`p = R / (β̂ · (1 − haircut) · Λ̂(t, T − buffer))` (R in DB units, demand in client units),
client rate `= min(p, 1 + h) · λ̂ᵢ`.
`Λ̂` comes from a learned daily profile of total demand × a level factor
(current demand / profile) that catches unknown weekly effects within hours.
`:uniform` strategy (`R / remaining time`) is available for comparison.

**4. Grants.** `τ = clamp(tau_frac·(T−t), tau_min, tau_max)` (shrinks near the end),
amount = rate · τ. Clients:
- renew shortly before expiry or exhaustion (prefetch, `renew_lead`);
- **re-grant** when their demand rose > 30% above what the grant was sized for;
- **partially return** reserved amount they cannot use (keep ≤ 2× expected use).
A new grant replaces the old one; with `return_unused` the old unused part is freed at once.

**5. Feasibility alert.** When projected remaining demand (× β) < remaining budget.

## Findings (40 seeds per scenario, see `out/sweep.txt`)

- Hard cap held in every scenario where assumptions are valid (0 overspend runs). Violating
  `D_max` or `β_max` → small but systematic overspend: these bounds must be conservative.
- Unknown weekly pattern was the first real failure: a learned *weekday* profile overestimated
  weekend demand at the end of the period → 98% spend. Fixed by the level factor + planning margin.
- Planning margin trade-off: `finish_buffer`/`forecast_haircut` buy robustness to a late demand drop
  (last 12 h at 30%: 96.9% → 99.1%) at the cost of finishing ~2–3 h early and front-loading spend.
- Volatile clients with long grants: without re-grant, rates go stale → 93–96% spend; with re-grant 100%.
- Early return matters only when the cap binds (end of period), and more when grants are large
  relative to the budget (5 volatile clients, τ = 240: 99.74% → 100.00%).
- Demand below B (ratio 0.9): spends ~92% (all it can), alert fires.
- β (DB/client ratio): the value does not matter (β̂ is learned); a `β_max` that is too small always
  overspends, one that is too large costs < 0.01% of B (`scripts/beta_sensitivity.jl`).

## Known limitations / next steps

- Day 1 has no profile → unthrottled start (warm-start with a profile from previous periods).
- The haircut is constant; a haircut that decays toward T would reduce front-loading.
- No client crashes (a crashed client cannot return its grant), no center outage, no request loss.
- Center throughput is not modelled (only counted: grants/min).

## License

MIT, see [LICENSE](LICENSE).

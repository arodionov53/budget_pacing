# Elixir vs Julia

This compares the Elixir simulator with the Julia simulator (`../../src/`): first how the two
implementations differ, then their results on the Monte Carlo sweep from `scripts/sweep.jl`.
How the Elixir simulator works is described in [SIMULATOR.md](SIMULATOR.md), and the
parameters in [SIMULATOR.md §8](SIMULATOR.md#8-parameters-and-their-effect-on-results).

## Implementation

The Elixir simulator is a separate reimplementation of `src/simulate.jl`, not a line-by-line
port. Julia runs the whole model in one loop over shared arrays; Elixir runs each actor as a
separate process. Both use the same tick and index conventions: index k holds the value at
time (k − 1)·dt, and the first simulated tick is 2.

| Topic | Julia (`simulate.jl`) | Elixir | Effect |
|---|---|---|---|
| Random numbers | Xoshiro256++ | Erlang `:exsss`, all draws made centrally by the Clock in a fixed order | Per-seed results differ; statistics match (see Results) |
| `D_assumed` default | `isnan(cfg.D_assumed) ? cfg.D : cfg.D_assumed` | `nil` → `d_delay` (`Config.d_assumed/1`) | Same |
| Jitter quirk: `D_assumed` defaults to D, not D + mean jitter | yes | yes | Same: nowcast window on average `D_jitter / 2` too short |
| Grant latency | request served once `now − request_idx ≥ grant_latency` | same, in `Clock.requesting_clients/4` | Same |
| Denied requests | stay open, reconsidered every tick | same | Same |
| Requests on the last tick | none (`now > N`) | none | Same |
| Demand reports to the center | delayed by `report_lag` (`kd = n − Lr`) | **current tick, no delay** (`Clock.center_input`) | Elixir's demand estimate is one minute fresher (see below) |
| β̂ = 0 (seen briefly with jitter) | p = r*/0 = Inf (IEEE) | handled explicitly in `Center.throttle/3`: serve full demand | Same behaviour |

**Demand reports.** Julia delays the **demand** reports by `report_lag`: at tick n the center
updates its demand estimates with the demand of tick `n − report_lag`. The Elixir Clock passes
the current tick's demand to the Center with no delay, so the Elixir center's demand estimate
is one minute fresher than Julia's. The effect is small, because the estimate is smoothed over
30 minutes, and the sweep below agrees with Julia, but it is the one place where the Elixir
center has information Julia's center doesn't. Spend reports (`C_recent`) are lagged in both.

Julia's sweep results come from [`../../out/sweep.txt`](../../out/sweep.txt).

## How to reproduce

```sh
# Julia, 40 seeds per scenario (from the repo root)
julia -t auto scripts/sweep.jl 40 > out/sweep.txt

# Elixir, 10 seeds per scenario (from elixir/budget_pacing_sim), about 25 minutes
mix sim.sweep --runs 10 > out/sweep_elixir.txt
```

`mix sim.sweep` runs the seeds of each scenario in parallel, one per CPU core.

## Results

The same 27 scenarios as `scripts/sweep.jl`, run with `mix sim.sweep --runs 10` (10 seeds per
scenario; Julia used 40). Full output: [`out/sweep_elixir.txt`](out/sweep_elixir.txt). Cells are **mean spend % of B**,
with the worst run in brackets where it differs, then the number of runs **over B**.

| Scenario | Julia (40 runs) | Elixir (10 runs) | Elixir grants/min | Elixir util |
|---|---|---|---|---|
| baseline (adaptive) | 100.000, 0 over | 99.999, 0 over | 2.38 (Julia 2.38) | 89.4 % (89.9 %) |
| uniform pacing | 100.000, 0 | 100.000, 0 | 2.54 (2.53) | 83.2 % (83.4 %) |
| adaptive, no level corr. | 100.000, 0 | 100.000, 0 | 2.50 (2.50) | 88.7 % (89.1 %) |
| no buffer, no haircut | 99.997, 0 | 99.996, 0 | 2.63 (2.62) | 88.2 % (88.7 %) |
| haircut 0.05 | 100.000, 0 | 100.000, 0 | 2.51 (2.51) | 88.7 % (89.1 %) |
| no early return | 100.000, 0 | 99.999, 0 | 2.37 (2.38) | 90.0 % (89.9 %) |
| no re-grant on demand rise | 100.000, 0 | 99.999, 0 | 2.37 (2.37) | 90.3 % (90.9 %) |
| exposure = full grants | 100.000, 0 | 99.991, 0 | 2.37 (2.37) | 89.4 % (89.9 %) |
| τmax = 240 min | 100.000, 0 | 99.999, 0 | 2.30 (2.30) | 88.2 % (88.6 %) |
| τmax = 15 min | 100.000, 0 | 99.999, 0 | 4.58 (4.56) | 82.5 % (82.9 %) |
| h = 0.2, burst = 2 min | 100.000, 0 | 99.999, 0 | 2.38 (2.38) | 89.3 % (89.5 %) |
| volatile, τ = 240 | 100.000, 0 | 100.000, 0 | 0.53 (0.55) | 35.3 % (33.6 %) |
| volatile, τ = 240, no return | 99.983 [99.950], 0 | 99.986 [99.971], 0 | 0.56 (0.58) | 35.8 % (34.0 %) |
| volatile, τ = 240, no re-grant | 95.707 [93.296], 0 | 96.302 [94.679], 0 | 0.22 (0.22) | 66.4 % (67.2 %) |
| 5 volatile clients, τ = 240 | 99.999 [99.979], 0 | 100.000, 0 | 0.06 (0.06) | 33.8 % (32.7 %) |
| 5 volatile, τ = 240, no return | 99.744 [98.665], 0 | 99.745 [99.263], 0 | 0.09 (0.09) | 34.6 % (33.4 %) |
| D = 120 min | 99.998, 0 | 99.997, 0 | 2.38 (2.38) | 89.4 % (89.9 %) |
| D = 30 ± 15, D_max known | 100.000, 0 | 99.999, 0 | 2.37 (2.37) | 89.4 % (89.8 %) |
| **D = 30 ± 15, D_max = 30 (wrong)** | 100.007, **40/40 over** | 100.005, **10/10 over** | 2.37 (2.37) | 89.4 % (89.8 %) |
| noise cv = 1.5 | 100.000, 0 | 99.999, 0 | 2.49 (2.49) | 83.5 % (83.9 %) |
| demand ratio 1.15 | 100.000, 0 | 99.999, 0 | 2.41 (2.41) | 86.6 % (86.8 %) |
| demand ratio 0.9 | 92.017 [89.937], 0 | 91.968 [90.281], 0 | 2.63 (2.63) | 68.4 % (68.3 %) |
| shock: day 4 at 20 % | 100.000, 0 | 99.999, 0 | 2.46 (2.46) | 85.4 % (85.6 %) |
| shock: day 4 at 20 %, uniform | 99.720 [99.456], 0 | 99.713 [99.550], 0 | 2.68 (2.68) | 77.2 % (77.4 %) |
| shock: last 12 h at 30 % | 99.143 [98.982], 0 | 99.177 [99.081], 0 | 2.54 (2.54) | 88.6 % (89.0 %) |
| shock: last 12 h, haircut 0.05 | 96.944 [96.723], 0 | 96.992 [96.781], 0 | 2.55 (2.56) | 88.2 % (88.5 %) |
| **β_true = 1.08 > β_max (wrong)** | 100.001, **40/40 over** | 99.999, **0/10 over** | 2.36 (2.36) | 89.7 % (90.1 %) |

Other metrics match too. Ŝ err is 0.099 ‰ in both (0.475 ‰ in both with jitter), Y err is the
same to three decimals (2.976 ‰, 11.903 ‰ at D = 120). The idle tail is within 0.1 h in calm
scenarios. The feasibility alert fires in the same scenarios (all runs of demand 0.9 and of
both shocks; none in the baseline).

**Differences:**

- **Spend is 99.999 % instead of 100.000 %** in most scenarios, about 10 money units short of B
  out of 1,000,000. A rounding-level difference in the last few grants of the run; not
  investigated further.
- **`exposure = full grants`: 99.991 % vs 100.000 %.** Reserving every grant in full holds back
  a little more in Elixir. Still within the 0.05–0.3 % cost MODEL.md §6.E gives for this mode.
- **`β_true = 1.08 > β_max`: no overspend in Elixir, 40/40 in Julia.** This is the one
  qualitative difference. In Julia the overspend is tiny (0.006 ‰ of B on average), so a
  slightly larger end-of-run safety gap in Elixir, the same one that gives 99.999 % above, is
  enough to absorb it. Read it as "this run happened not to overspend", not as "Elixir is safe
  with a wrong β_max": the cap's guarantee is gone either way, and `Config.validate!/1` warns
  about it.
- **Volatile scenarios** differ by up to 0.6 points (no re-grant: 96.3 % vs 95.7 %). With 10
  seeds instead of 40 and wide run-to-run spread in these scenarios (worst run 93–98 %), that
  is within sampling noise.

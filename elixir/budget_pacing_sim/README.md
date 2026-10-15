# Budget Pacing Simulator (Elixir)

OTP application that simulates budget pacing with delayed spend data, reproducing the model described in [MODEL.md](../../MODEL.md) and [PACING.md](../../PACING.md).

Each logical actor is a separate GenServer process:

- **Client** — demand generation (daily pattern + OU drift + noise), token-bucket local pacing, grant lifecycle (request, renew, re-grant, partial return), reporting.
- **Center** — EWMA demand estimation, daily profile with level factor, β̂ estimation, nowcast, pacing law (uniform or adaptive), hard-cap invariant, grant issuance.
- **CentralDB** — true spend accumulation with β·(1+ε) noise, delayed + jittered observations.
- **Clock** — deterministic lock-step tick driver, seeded RNG, metrics collection.

## Quick start

```sh
cd elixir/budget_pacing_sim
mix deps.get
mix compile

# Run with defaults (adaptive strategy, seed=1, 7-day period, 50 clients)
mix sim

# Human-readable table output
mix sim --format table

# Custom config + time-series CSV
mix sim --config priv/default_config.toml --seed 42 --record out/run.csv
```

## Configuration

All 37 parameters are loaded from a TOML file. Missing keys use defaults matching the Julia simulator. See [`priv/default_config.toml`](priv/default_config.toml) for the full list with comments.

Key parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `b` | 1,000,000 | Total budget (hard cap) |
| `t` | 10,080 | Period in minutes (7 days) |
| `n_clients` | 50 | Number of clients |
| `demand_ratio` | 1.5 | Total mean demand / (B/T) |
| `strategy` | `"adaptive"` | `"uniform"` or `"adaptive"` |
| `level_minutes` | 240 | Level factor EWMA window (0 = disable) |
| `d_delay` | 30 | DB observation delay in minutes |
| `forecast_haircut` | 0.2 | Deliberate pessimism in pacing |
| `seed` | 1 | Random seed for reproducibility |

### Three pacing strategies

| Strategy | Config |
|---|---|
| Uniform | `strategy = "uniform"` |
| Adaptive, no level factor | `strategy = "adaptive"`, `level_minutes = 0` |
| Adaptive (default, best) | `strategy = "adaptive"`, `level_minutes = 240` |

## Analysis tools

### `mix sim` — single run

```sh
mix sim                              # JSON summary to stdout
mix sim --format table               # aligned text table
mix sim --seed 5 --record out.csv    # time-series CSV for plotting
```

### `mix sim.compare` — strategy comparison

Runs all three strategies on the same seed, writes CSV per strategy, and prints a metrics table. Optionally runs a late demand shock scenario.

```sh
mix sim.compare --seed 1 --out-dir out/
```

Output:
- `out/pacing_uniform.csv`, `out/pacing_adaptive_nolevel.csv`, `out/pacing_adaptive.csv`
- `out/pacing_shock_*.csv` (same strategies with last-12h demand drop to 30%)
- Markdown table with per-strategy metrics (throttle median, served at peak/night, etc.)

### `mix sim.sweep` — Monte Carlo sweep

Runs multiple seeds across 27 scenarios (policy choices, volatile clients, delay, demand shocks, safety assumptions). Prints an aligned table like the Julia `scripts/sweep.jl`.

```sh
mix sim.sweep --runs 10              # 10 seeds per scenario (default)
mix sim.sweep --runs 40 --format markdown
```

## CSV format

All CSV files share the same columns, compatible with the Julia plot scripts:

```
t,s,y,s_hat,e,demand,spend,p,beta_hat
```

| Column | Meaning |
|---|---|
| `t` | Time in minutes |
| `s` | True cumulative DB spend S(t) |
| `y` | Delayed observation Y |
| `s_hat` | Nowcast Ŝ |
| `e` | Exposure E (open grants) |
| `demand` | Demand rate (money/min, averaged over record_every ticks) |
| `spend` | Spend rate (money/min, averaged) |
| `p` | Effective throttle (granted rate / demand) |
| `beta_hat` | Center's estimate of β |

Plot with the existing Julia scripts, gnuplot, or Python:

```sh
# Julia (from repo root)
julia --project=plots plots/plot.jl elixir/budget_pacing_sim/out/run.csv out/run_elixir.png

# gnuplot one-liner
gnuplot -e "set datafile separator ','; plot 'out/run.csv' using 1:2 with lines title 'S(t)'"

# Python
import pandas as pd; df = pd.read_csv('out/run.csv'); df.plot(x='t', y=['s','y','s_hat'])
```

## Tests

```sh
mix test                       # all tests (64 unit + 2 integration)
mix test --exclude integration # unit tests only (~0.1s)
```

## Architecture

```
Clock (tick driver, RNG)
├── calls → Client_1..N  (demand, spend, report)
├── calls → CentralDB    (record spend, observe Y)
└── calls → Center       (estimation, pacing, grants)
                ├── reads → CentralDB (exposure lookups)
                └── issues grants → Client_1..N
```

All communication is synchronous `GenServer.call` in lock-step: tick N completes everywhere before tick N+1 begins. This guarantees deterministic, reproducible results for a given seed.

## Relation to the Julia simulator

This is a separate reimplementation, not a port. The Julia simulator (`src/`) is a monolithic single-threaded loop; the Elixir version uses OTP processes. Both implement the same model and produce statistically equivalent results, but they use different RNG algorithms (Erlang `:exsss` vs Julia Xoshiro256++), so per-seed outputs are not bit-identical.

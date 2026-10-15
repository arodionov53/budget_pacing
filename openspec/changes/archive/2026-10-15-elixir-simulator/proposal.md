# Proposal

## Why

The existing Julia simulator is a monolithic, single-threaded loop. The real system is distributed: independent clients, a central controller, and a central DB that communicate via messages with latency. An Elixir reimplementation models this naturally—each client, the center, and the DB are separate OTP GenServer processes that exchange messages, making communication delays, ordering, and concurrency explicit rather than faked by array offsets.

## What Changes

- **New Elixir/OTP application** (`budget_pacing_sim`) that reproduces the simulation described in MODEL.md and PACING.md.
- **Client GenServers** (one per simulated client): own their demand generation (daily pattern + OU drift + noise), token-bucket pacing, grant lifecycle (renew, re-grant, partial return), and send reports to the center.
- **Center GenServer**: receives reports and DB observations, runs estimation (EWMA demand, profile × level, β̂, nowcast), computes the throttle (uniform or adaptive + level factor), enforces the hard-cap invariant, and issues grants.
- **CentralDB GenServer**: accumulates true spend, applies the β factor and noise, and serves delayed observations (Y = S(t − D − jitter)) to the center.
- **Simulation clock**: a discrete-tick driver (1 min per tick) that advances all servers in lock-step so runs are deterministic and reproducible with a seed, matching the Julia simulator's behaviour.
- **Config from file**: all world, center-assumption, and policy parameters (the full `Config` struct from `src/config.jl`) loaded from a TOML or YAML config file at startup, with the same defaults as the Julia version.
- **Metrics collection**: the same summary metrics and optional time-series recording as the Julia simulator, written to stdout or a file.

## Capabilities

### New Capabilities
- `sim/client`: Client process — demand generation, token-bucket local pacing, grant lifecycle (request, renew, re-grant, partial return), and reporting.
- `sim/center`: Center process — estimation (demand EWMA, daily profile, level factor, β̂, nowcast), pacing law (uniform / adaptive), hard-cap invariant, exposure accounting, and grant issuance.
- `sim/central-db`: Central DB process — true spend accumulation, β·(1+ε) recording, delayed+jittered observation serving.
- `sim/clock`: Simulation clock — deterministic discrete-tick driver that advances all processes in lock-step, seeded RNG, and run lifecycle.
- `sim/config`: Configuration — loading all simulator parameters from a config file, defaults, and validation.

### Modified Capabilities
<!-- No existing specs. -->

## Impact

- **New dependency**: Elixir ≥ 1.15 / OTP ≥ 26, plus a config-parsing library (e.g. `toml` hex package).
- **No changes** to the existing Julia code, docs, or scripts. The Elixir simulator is a separate application that can be validated against the Julia results.
- **Repository structure**: new `elixir/` directory at the repo root containing the Mix project.

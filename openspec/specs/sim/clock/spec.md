# sim/clock Specification

## Purpose

Simulation clock that drives all processes through deterministic discrete ticks, manages the seeded RNG, and controls the run lifecycle from start to metrics output.

## Requirements

### Requirement: Discrete tick advancement
The clock SHALL advance time in steps of Δt = dt minutes, from t = 0 to t = T, for a total of T/dt ticks. Each tick SHALL be processed by all servers before the next tick begins (lock-step).

#### Scenario: One full simulation run
- **WHEN** the clock is started with T = 7 days and dt = 1 min
- **THEN** exactly 10080 ticks are executed and every tick completes across all processes before the next begins

### Requirement: Deterministic seeded RNG
The clock SHALL initialize a PRNG from the configured seed. All random draws (demand noise, OU drift, DB noise, jitter) SHALL use this RNG so that the same seed + config produces identical results.

#### Scenario: Reproducibility
- **WHEN** two runs use the same seed and config
- **THEN** the final S(T), all per-tick demand values, and all metrics are identical

### Requirement: Lock-step ordering
Within each tick the clock SHALL enforce the ordering: (1) clients generate demand and spend, (2) clients send reports, (3) center observes DB and reports, (4) center issues grants. This matches the Julia simulator's within-tick sequence.

#### Scenario: Report arrives before center computes
- **WHEN** tick n executes
- **THEN** the center's estimation and grant issuance for tick n use reports and DB values that include tick n's client actions

### Requirement: Metrics collection
The clock SHALL collect summary metrics (spend_ratio, overspend, underspend, grants_per_min, utilization, est_err, naive_err, finish_early, alert_minutes) and, when recording is enabled, time-series sampled every record_every ticks.

#### Scenario: Summary output
- **WHEN** the simulation completes
- **THEN** the clock outputs a summary map containing at minimum spend_ratio, overspend, grants_per_min, utilization, and finish_early

#### Scenario: Time-series recording
- **WHEN** recording is enabled and record_every = 10
- **THEN** one time-series sample is emitted every 10 ticks with fields t, S, Y, Ŝ, E, demand, spend, p, beta_hat

### Requirement: Run lifecycle
The clock SHALL start all server processes, run the tick loop, collect final metrics, and stop all servers. A failed server SHALL cause the simulation to halt with an error.

#### Scenario: Clean shutdown
- **WHEN** the last tick completes
- **THEN** all GenServers are stopped and the caller receives the summary and time-series data

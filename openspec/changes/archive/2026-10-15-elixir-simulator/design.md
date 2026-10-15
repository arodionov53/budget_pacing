# Design

## Context

See proposal.md — Why. The Julia simulator (`src/simulate.jl`) runs the full model in a single 260-line function: one `for n in 1:N` loop that mutates shared arrays for client spend, DB spend, and center state. All communication (reports, grants, DB reads) is simulated by reading from these arrays at offset indices. The Elixir version replaces array offsets with message passing between GenServer processes while keeping identical numerical behaviour so the two simulators can be cross-validated.

The Julia `Config` struct has 37 parameters grouped into world, center assumptions, and policy. The Elixir config must carry exactly the same parameters with the same defaults.

## Goals / Non-Goals

**Goals:**
- Numerically reproduce the Julia simulator's results for any given seed and config (cross-validation).
- Each logical actor (client, center, DB) is a separate GenServer with its own state.
- Deterministic, reproducible runs despite multiple processes.
- Config loaded from a file; CLI entrypoint for running a simulation.

**Non-Goals:**
- Real-time or wall-clock pacing (the simulator runs as fast as possible in lock-step ticks).
- Distributed deployment across multiple BEAM nodes.
- A web UI or API — output is stdout / file.
- Replacing the Julia simulator; both coexist.
- Monte Carlo / multi-seed sweep harness (single run only; sweeps can be scripted externally).

## Decisions

### 1. Supervision tree structure

```
BudgetPacingSim.Application
└── Simulation.Supervisor (one_for_all)
    ├── CentralDB (GenServer)
    ├── Center (GenServer)
    ├── Client.Supervisor (one_for_one, n_clients children)
    │   ├── Client_1 (GenServer)
    │   ├── Client_2 (GenServer)
    │   └── ...
    └── Clock (GenServer, started last)
```

**Why one_for_all at the top**: if any server crashes, the simulation is invalid — restart all or fail. Individual client crashes under `Client.Supervisor` propagate up.

**Alternative considered**: DynamicSupervisor for clients. Rejected — the client set is fixed at startup, and static children are simpler to address by index.

### 2. Deterministic tick protocol (lock-step)

The Clock drives every tick synchronously with `GenServer.call`:

```
Clock                          Clients (all)      CentralDB       Center
  |--- :tick (call) -----------> each client       |               |
  |    client generates demand,  |                 |               |
  |    spends, prepares report   |                 |               |
  |<-- {:ok, report} -----------|                  |               |
  |--- :record_spend (call) ----|----------------> DB              |
  |<-- :ok -----------------------------------------|              |
  |--- :tick (call) ------------|------------------|--> Center     |
  |    Center reads DB (call),  |                  |    processes   |
  |    issues grants (call to   |                  |    reports     |
  |    clients)                 |                  |               |
  |<-- {:ok, grants_issued} ---|------------------|----|          |
```

All calls are synchronous (`GenServer.call`), so the tick cannot advance until every step completes. This guarantees the same within-tick ordering as the Julia loop: clients act → DB records → center observes and issues grants.

**Why not async messages**: determinism requires that step N finishes everywhere before step N+1 begins. Async messages + barriers would add complexity for no benefit in a simulated-time system.

**Alternative considered**: a single process with modules (no GenServers). Rejected — it loses the architectural goal of separate servers with message passing.

### 3. RNG distribution

A single `:rand` seed is set in the Clock process at startup. The Clock generates all random numbers for each tick (demand noise per client, OU drift per client, DB β noise per client, DB jitter) and distributes them to the respective servers as part of the tick message. This ensures the random stream is consumed in exactly the same order as the Julia simulator.

**Why not per-process RNG**: multiple processes consuming independent RNGs would not reproduce the Julia simulator's single-stream draws. Cross-validation requires identical sequences.

**Alternative considered**: pass the RNG state through processes in sequence. More complex and fragile — centralized draws are simpler.

### 4. State representation

Each GenServer's state is an Elixir struct:

- **`Client.State`**: `mu, phase, logdrift, grant (Grant struct or nil), tokens, used, cum_spend, request_tick, lam_own`
- **`Center.State`**: `grants (list), unsettled (list of ids), lam (list), lam_long, initialized, beta_hat, ew_dY, ew_dC, prev_Y, prev_C, profile (list), seen (list), cur_bin, bin_acc, bin_cnt, level`
- **`CentralDB.State`**: `s_db (list of cumulative spend per tick), ccli (map of client_id → list), ctot (list)`
- **`Clock.State`**: `tick (current), config, rng_state, metrics_acc, ts_acc`

Historical arrays (Ccli, Sdb, Ctot) live in CentralDB because that is where they are needed for exposure lookups. The center queries them via `GenServer.call`.

**Why lists not ETS**: the arrays are append-only and accessed by index. A list of values with `Enum.at` is O(n) but n ≤ 10080, which is negligible. ETS would add shared-state complexity counter to the design goal. If profiling shows it matters, `:array` (Erlang's functional array) or `:atomics` can be substituted without changing the API.

### 5. Config format: TOML

TOML is chosen because:
- The parameter set is flat (three groups: world, center, policy) with no nesting beyond one level.
- The `toml` hex package is mature and dependency-free.
- Julia ecosystem also uses TOML, so users see the same format.

**Alternative considered**: YAML (more common in Elixir). Rejected — `yaml_elixir` pulls in a larger dependency tree, and TOML's typed scalars (float vs int) avoid silent coercion bugs.

Config is parsed into a `%Config{}` struct at startup. The struct is immutable and passed to each GenServer's `init/1`.

### 6. Elixir project layout

```
elixir/
├── mix.exs
├── config/
│   └── config.exs          # compile-time defaults (if any)
├── lib/
│   └── budget_pacing_sim/
│       ├── application.ex
│       ├── config.ex        # Config struct, TOML loading, validation
│       ├── model.ex         # Pure functions: base_pattern, shock, exposure, remaining_demand
│       ├── client.ex        # Client GenServer
│       ├── center.ex        # Center GenServer
│       ├── central_db.ex    # CentralDB GenServer
│       ├── clock.ex         # Clock GenServer (tick driver, RNG, metrics)
│       └── grant.ex         # Grant struct
├── test/
│   ├── config_test.exs
│   ├── model_test.exs
│   ├── client_test.exs
│   ├── center_test.exs
│   ├── central_db_test.exs
│   ├── clock_test.exs
│   └── integration_test.exs # cross-validates against Julia output
└── priv/
    └── default_config.toml  # reference config with all defaults documented
```

### 7. CLI entrypoint

`mix run --no-halt` with a Mix task `mix sim` or an escript. The task accepts `--config path/to/config.toml` and `--seed N` (overrides config). Output: JSON summary to stdout; optional `--record path.csv` for time series.

## Risks / Trade-offs

- **[Numerical parity]** Elixir uses IEEE 754 doubles like Julia, but `:rand` algorithms differ from Julia's Xoshiro. → Mitigation: for cross-validation, implement a thin Xoshiro256++ NIF or accept that parity means "same statistics" not "bit-identical per seed". Start with Erlang's default algorithm and compare distributions; add Xoshiro only if exact seed parity is required.
- **[Performance]** GenServer.call per client per tick adds ~μs overhead × 50 clients × 10080 ticks ≈ 0.5 s. The Julia version runs in 0.15 s. → Acceptable for a design-exploration tool; not a bottleneck. If needed, batch client ticks in the Clock process.
- **[Historical array growth]** Storing 10080 entries per client (50 clients × 10080 = 504k floats) is ~4 MB. Acceptable.
- **[Lock-step limits concurrency]** The synchronous tick protocol means clients don't run in parallel within a tick. → This is intentional for determinism. True concurrency testing would require a different clock design (event-driven / virtual time), which is a non-goal.

## Open Questions

- **Exact Xoshiro parity**: should the Elixir simulator produce bit-identical results to the Julia one for the same seed, or is statistical equivalence sufficient? This affects whether a Xoshiro256++ NIF is needed. Does not change the architecture or task breakdown.

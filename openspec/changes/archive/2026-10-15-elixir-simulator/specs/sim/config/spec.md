# Spec Delta

## Purpose

Configuration loading and validation — reads all simulator parameters from a TOML config file, applies defaults matching the Julia simulator, and validates constraints before the simulation starts.

## ADDED Requirements

### Requirement: Load from TOML file
The system SHALL read a TOML config file and populate all simulator parameters. Missing keys SHALL use the default values defined in the Julia Config struct.

#### Scenario: Partial config file
- **WHEN** the config file sets only B = 500000 and n_clients = 20
- **THEN** all other parameters use their defaults (T = 10080, dt = 1, demand_ratio = 1.5, etc.)

#### Scenario: Full config file
- **WHEN** every parameter is specified in the TOML file
- **THEN** all values are loaded as specified with no defaults applied

### Requirement: Default values
All parameters SHALL have defaults matching the Julia simulator: B = 1e6, T = 10080 (7 days in minutes), dt = 1, n_clients = 50, demand_ratio = 1.5, size_spread = 0.8, noise_cv = 0.5, daily_amp = 0.6, weekly_amp = 0.3, D = 30, beta_true = 1.02, beta_max = 1.06, strategy = adaptive, finish_buffer = 60, forecast_haircut = 0.2, tau_max = 60, ewma_minutes = 30, seed = 1.

#### Scenario: No config file
- **WHEN** the simulator is started without a config file path
- **THEN** all parameters use the defaults and the simulation runs the baseline scenario

### Requirement: Derived defaults
D_assumed SHALL default to D when not set. D_max SHALL default to D + D_jitter when not set.

#### Scenario: D_max derived
- **WHEN** D = 30 and D_jitter = 15 and D_max is not set
- **THEN** D_max is 45

### Requirement: Validation
The system SHALL validate: strategy is "uniform" or "adaptive"; exposure_mode is "reported" or "full"; nowcast is "reports" or "none"; beta_max ≥ beta_true·(1 + 3·beta_noise) (warn if not); D + D_jitter ≤ D_max (warn if not); renew_lead > grant_latency (warn if not).

#### Scenario: Invalid strategy
- **WHEN** the config file sets strategy = "greedy"
- **THEN** the system exits with an error naming the invalid value

#### Scenario: Safety warning
- **WHEN** beta_true = 1.08 and beta_max = 1.06
- **THEN** the system logs a warning that beta_max may be too small but does not halt

### Requirement: Config as a struct
The loaded config SHALL be represented as an immutable struct (or map with enforced schema) that can be passed to all server processes at startup.

#### Scenario: Struct access
- **WHEN** a server process receives the config
- **THEN** it can access any parameter by name (e.g., config.B, config.n_clients)

# Spec Delta

## Purpose

Central DB process that accumulates the true authoritative spend, applies the β factor with per-transaction noise, and serves delayed observations to the center.

## ADDED Requirements

### Requirement: Spend recording
The DB SHALL record each client's spend as β_true·(1 + ε) where ε ~ N(0, beta_noise²) clipped at ±3σ. The cumulative sum S(t) is the true authoritative spend.

#### Scenario: Normal spend recording
- **WHEN** client i spends amount c in a tick
- **THEN** the DB adds c · β_true · (1 + clamp(ε, −3·beta_noise, 3·beta_noise)) to S

### Requirement: Delayed observation
The center SHALL observe Y(t) = S(t − D − j) where j ~ U[0, D_jitter], and the observed time SHALL never go backwards (monotonic).

#### Scenario: Observation with jitter
- **WHEN** D = 30 min and D_jitter = 15 min
- **THEN** the center sees a value from between 30 and 45 minutes ago, and never an older value than previously observed

#### Scenario: Zero jitter
- **WHEN** D_jitter is 0
- **THEN** the center always sees S(t − D) with no randomness in the delay

### Requirement: Per-tick cumulative totals
The DB SHALL maintain per-client cumulative counted spend (before β) and per-tick total DB spend, accessible for exposure calculations at any past index.

#### Scenario: Historical lookup
- **WHEN** the center needs client i's cumulative counted spend at index s for exposure calculation
- **THEN** the DB returns the exact value Ccli[i, s]

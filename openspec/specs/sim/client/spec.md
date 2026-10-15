# sim/client Specification

## Purpose

Client process that generates demand, paces spend through a token bucket, manages its grant lifecycle (request, renew, re-grant, partial return), and reports counted spend and demand to the center.

## Requirements

### Requirement: Demand generation
Each client SHALL generate demand every tick as d = max(0, m·Δt + cv·m·√Δt·ξ) where m = μ·P(t+φ)·shock(t)·exp(x−σ²/2), with OU drift on x, per-client phase shift φ, and daily/weekly pattern P.

#### Scenario: Demand at a normal weekday tick
- **WHEN** the clock advances one tick on a Wednesday with no shock active
- **THEN** the client produces demand using the daily pattern P, its OU drift state, and Gaussian noise, and the demand is non-negative

#### Scenario: Demand during a shock window
- **WHEN** the current time falls within [shock_start, shock_start + shock_length)
- **THEN** the demand rate m is multiplied by shock_factor

#### Scenario: Demand on a weekend
- **WHEN** the current day is Saturday or Sunday
- **THEN** the weekly pattern reduces demand by the configured weekly_amp factor

### Requirement: Token-bucket local pacing
The client SHALL pace its spend through a token bucket that fills at the grant rate and holds at most burst_minutes × rate tokens. Spend per tick SHALL be min(demand, tokens, amount_remaining).

#### Scenario: Demand exceeds tokens
- **WHEN** the client has demand of 10 but only 3 tokens available
- **THEN** the client spends 3 and the remaining demand is lost

#### Scenario: Bucket refill
- **WHEN** a new tick begins and the client holds an active grant
- **THEN** tokens increase by rate·Δt, capped at burst_minutes × rate

### Requirement: Grant request
The client SHALL request a new grant when it has no active grant, when fewer than renew_lead minutes of time or money remain, or when its own demand EWMA has risen more than regrant_threshold above the grant's issue-time demand estimate.

#### Scenario: No active grant
- **WHEN** the client's grant has expired or it never received one
- **THEN** the client sends a grant request to the center

#### Scenario: Re-grant on demand surge
- **WHEN** the client's EWMA demand exceeds (1 + regrant_threshold) × the grant's lam_issue
- **THEN** the client sends a re-grant request

### Requirement: Partial return
When return_unused is enabled, the client SHALL keep at most return_keep_factor × min(rate, own_demand_ewma) × time_remaining of its grant amount and return the excess to the center. The rate is unchanged.

#### Scenario: Demand drops below grant sizing
- **WHEN** the client's demand EWMA drops so that excess > max(min_grant, 0.1 × grant_amount)
- **THEN** the client reduces the grant amount and notifies the center of the returned portion

### Requirement: Reporting
Each tick the client SHALL report its cumulative counted spend and per-tick demand to the center, subject to report_lag delay.

#### Scenario: Normal report
- **WHEN** a tick completes and report_lag ticks have elapsed since the spend occurred
- **THEN** the center receives the client's cumulative spend and demand for that tick

### Requirement: Grant expiry
When a grant's expiry time is reached, the client SHALL stop spending from it and the unused amount SHALL be freed.

#### Scenario: Grant expires with unused amount
- **WHEN** the current tick reaches or exceeds the grant's expiry index
- **THEN** the client stops spending, sets switch_idx and release_idx, and clears its active grant

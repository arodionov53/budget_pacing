# Spec Delta

## Purpose

Center process that receives client reports and DB observations, estimates demand and β, computes the pacing throttle (uniform or adaptive with level factor), enforces the hard-cap invariant, and issues grants to clients.

## ADDED Requirements

### Requirement: Demand estimation
The center SHALL maintain a per-client demand rate estimate (EWMA, 30 min window) and a long-run total demand EWMA (1 day window) from client reports received with report_lag delay.

#### Scenario: EWMA update on report
- **WHEN** the center receives a demand report from client i for tick k
- **THEN** λ̂_i is updated as λ̂_i += α·(d/Δt − λ̂_i) with α = Δt/ewma_minutes

#### Scenario: First report initializes estimates
- **WHEN** the center receives the very first demand report
- **THEN** per-client estimates are set directly to the reported rate (no smoothing)

### Requirement: Daily profile and level factor
The center SHALL learn a daily demand profile (profile_bins bins) by blending each day's average with weight profile_alpha. It SHALL maintain a level factor (EWMA, level_minutes window) as the ratio of current total demand to the profile value at the current bin.

#### Scenario: Profile bin update at bin boundary
- **WHEN** the current time moves into a new 15-min bin
- **THEN** the previous bin's profile value is updated as (1−α)·old + α·average, where α = profile_alpha

#### Scenario: Level factor during weekend
- **WHEN** Saturday demand runs at 70% of the weekday-learned profile
- **THEN** the level factor drops toward 0.7 within a few hours, scaling down the remaining-demand forecast

### Requirement: Beta estimation
The center SHALL estimate β̂ = EWMA(ΔY) / EWMA(ΔC) with a 4-hour EWMA window, where ΔY is the DB increment and ΔC is the aligned client-reported spend increment.

#### Scenario: Steady-state β convergence
- **WHEN** the true β is 1.02 and beta_noise is 0.01
- **THEN** β̂ converges to approximately 1.02 after several hours of observations

### Requirement: Nowcast
When nowcast mode is :reports, the center SHALL compute Ŝ = Y + β̂·(C_total(now−report_lag) − C_total(now−D_assumed)). When nowcast is :none, Ŝ = Y.

#### Scenario: Nowcast reduces estimation error
- **WHEN** D = 30 min and the center uses the nowcast
- **THEN** mean |Ŝ − S| is roughly 30× smaller than |Y − S|

### Requirement: Pacing law — uniform
When strategy is :uniform, the center SHALL compute r* = R / ((1−h_c)·(T_plan − t)) and p = r* / (β̂·Σλ̂_i).

#### Scenario: Uniform throttle varies with demand
- **WHEN** daytime demand is high and nighttime demand is low
- **THEN** p drops at the peak and rises (up to 1+demand_headroom cap) at night

### Requirement: Pacing law — adaptive
When strategy is :adaptive, the center SHALL compute r* = R · Λ_now / ((1−h_c)·Λ(t, T_plan)) where Λ(t,T) integrates level·profile(s) from t to T, and p = r* / (β̂·Σλ̂_i).

#### Scenario: Adaptive throttle stays roughly constant
- **WHEN** the adaptive strategy is active with a learned profile
- **THEN** p stays in a narrow band (e.g. 0.55–0.70) throughout the day

### Requirement: Inside finish buffer
When t > T − finish_buffer, the center SHALL set r* = ∞ (serve all demand), letting the hard cap be the only limit.

#### Scenario: Buffer period reached
- **WHEN** the current time exceeds T − finish_buffer
- **THEN** grants are issued at (1+demand_headroom)·λ̂_i with no throttle restriction

### Requirement: Hard-cap invariant
The center SHALL compute exposure E = Σ_k e_k over unsettled grants. A new grant g is issued only if Y + E + β_max·g ≤ B·(1−δ). The grant amount MAY be cut to fit.

#### Scenario: Grant denied by hard cap
- **WHEN** issuing a grant of amount g would cause Y + E + β_max·g > B·(1−δ)
- **THEN** the grant is either reduced to fit or denied entirely (if below min_grant)

#### Scenario: Exposure accounting with reported counters
- **WHEN** exposure_mode is :reported and a client has counted spend u on its grant
- **THEN** the grant's exposure is β_max·(amount − u_safe) where u_safe is the spend known to be included in Y

### Requirement: Grant issuance
The center SHALL issue grants with rate = min(p, 1+demand_headroom)·λ̂_i, duration τ = clamp(tau_frac·(T−t), tau_min, tau_max), and amount = rate·τ. Grants below min_grant are not issued.

#### Scenario: Grant replaces existing grant with return
- **WHEN** a client requests a new grant while holding an active one and return_unused is true
- **THEN** the old grant is switched off immediately, its unused amount is freed, and a new grant is issued

### Requirement: Feasibility alert
After day 1, the center SHALL raise an alert when β̂·Λ(t, T) < R and R > alert_tol·B.

#### Scenario: Demand below budget
- **WHEN** demand_ratio is 0.9 and total expected demand cannot fill the remaining budget
- **THEN** the feasibility alert fires

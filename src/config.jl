"""
    Config(; kwargs...)

All simulator parameters. Time unit: minutes. Money unit: arbitrary.

Parameters are grouped into
- the *world* (true demand, true DB behaviour) — unknown to the center,
- the *center's assumptions* (what it believes about delays and DB/client mismatch),
- the *policy* (pacing strategy and grant sizing).
"""
Base.@kwdef struct Config
    # ---------------- budget & horizon ----------------
    B::Float64 = 1.0e6                   # total budget, hard cap
    T::Float64 = 7 * 1440.0              # period [min] (starts Monday 00:00)
    dt::Float64 = 1.0                    # simulation step [min]

    # ---------------- world: client demand ----------------
    n_clients::Int = 50
    demand_ratio::Float64 = 1.5          # mean total demand / (B/T)
    size_spread::Float64 = 0.8           # lognormal σ of client sizes
    noise_cv::Float64 = 0.5              # Gaussian noise per step, relative to mean rate
    daily_amp::Float64 = 0.6             # demand ∝ 1 + daily_amp·sin(..), trough at midnight
    daily_phase_jitter::Float64 = 60.0   # per-client daily phase shift, std [min]
    weekly_amp::Float64 = 0.3            # weekend (Sat, Sun) demand reduction
    drift_sigma::Float64 = 0.15          # slow multiplicative drift of each client (OU on log)
    drift_tau::Float64 = 360.0           # drift correlation time [min]
    shock_start::Float64 = Inf           # optional demand shock window [min]
    shock_length::Float64 = 0.0
    shock_factor::Float64 = 1.0          # demand multiplier inside the shock window

    # ---------------- world: central DB ----------------
    D::Float64 = 30.0                    # DB delay [min]
    D_jitter::Float64 = 0.0              # extra delay, uniform in [0, D_jitter] [min]
    beta_true::Float64 = 1.02            # DB amount / client-counted amount
    beta_noise::Float64 = 0.01           # relative noise of that ratio per client-step (clipped ±3σ)
    report_lag::Float64 = 1.0            # latency of client usage/demand reports [min]

    # ---------------- center's assumptions (safety) ----------------
    D_assumed::Float64 = NaN             # delay used for estimation (NaN → D)
    D_max::Float64 = NaN                 # delay bound used for the hard-cap invariant (NaN → D + D_jitter)
    beta_max::Float64 = 1.06             # upper bound of DB/client ratio used for the hard cap
    delta::Float64 = 0.0                 # extra safety margin, fraction of B
    exposure_mode::Symbol = :reported    # :reported (use client counters) | :full (full grant amounts)
    return_unused::Bool = true           # clients may return unused grant early
    regrant_threshold::Float64 = 0.3     # client asks for a bigger grant when its demand rose more than
                                         # this fraction above what the grant was sized for (Inf = never)
    return_keep_factor::Float64 = 2.0    # partial return: client keeps ≤ factor × its expected use until
                                         # expiry and returns the rest (0 = never; needs return_unused)

    # ---------------- policy: pacing ----------------
    strategy::Symbol = :adaptive         # :uniform | :adaptive (learns daily demand profile)
    nowcast::Symbol = :reports           # :reports (Y + β̂·reported spend in the blind window) | :none (pace on Y)
    demand_headroom::Float64 = 0.5       # grant rate ≤ (1+h)·client demand estimate
    ewma_minutes::Float64 = 30.0         # smoothing of per-client demand estimate
    beta_ewma_minutes::Float64 = 240.0   # smoothing of β̂ (DB vs client reports)
    profile_bins::Int = 96               # daily profile resolution (96 → 15 min)
    profile_alpha::Float64 = 0.5         # weight of the newest day in the learned profile
    level_minutes::Float64 = 240.0       # smoothing of demand level vs profile (0 = no level correction)
    finish_buffer::Float64 = 60.0        # pace as if the period ends this much earlier [min]
    forecast_haircut::Float64 = 0.2      # plan as if future demand is this fraction lower than forecast

    # ---------------- policy: grants ----------------
    tau_frac::Float64 = 0.01             # τ = clamp(tau_frac·(T−t), tau_min, tau_max)
    tau_min::Float64 = 5.0
    tau_max::Float64 = 60.0
    renew_lead::Float64 = 3.0            # request next grant when < lead minutes of grant left
    grant_latency::Float64 = 1.0         # request → grant delivery [min]
    burst_minutes::Float64 = 5.0         # client token bucket size, in minutes of grant rate
    min_grant::Float64 = 1.0             # smaller grants are not issued
    alert_tol::Float64 = 0.001           # feasibility alert ignores remaining budget below alert_tol·B

    # ---------------- run ----------------
    seed::Int = 1
    record_every::Int = 10               # time-series sampling [steps]
end

d_assumed(cfg::Config) = isnan(cfg.D_assumed) ? cfg.D : cfg.D_assumed
d_max(cfg::Config) = isnan(cfg.D_max) ? cfg.D + cfg.D_jitter : cfg.D_max

function validate(cfg::Config)
    cfg.strategy in (:uniform, :adaptive) || error("strategy must be :uniform or :adaptive")
    cfg.exposure_mode in (:reported, :full) || error("exposure_mode must be :reported or :full")
    cfg.nowcast in (:reports, :none) || error("nowcast must be :reports or :none")
    cfg.renew_lead > cfg.grant_latency || @warn "renew_lead ≤ grant_latency: clients will idle between grants"
    d_max(cfg) >= cfg.report_lag || error("D_max must be ≥ report_lag")
    cfg.beta_true * (1 + 3cfg.beta_noise) <= cfg.beta_max ||
        @warn "true DB/client ratio can exceed beta_max: hard cap is not guaranteed"
    cfg.D + cfg.D_jitter <= d_max(cfg) ||
        @warn "true delay can exceed D_max: hard cap is not guaranteed"
    nothing
end

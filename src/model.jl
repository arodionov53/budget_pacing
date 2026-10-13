const DAY = 1440.0

# Index convention: cumulative arrays (spend, counters) have N+1 entries; index k is the
# value at time (k-1)·dt. Step n moves the system from index n to index n+1.

"""
A grant: the client may spend at most `amount` (client-counted) at pace `rate`
while `issue_idx ≤ index < expiry_idx`.
"""
mutable struct Grant
    client::Int
    amount::Float64
    rate::Float64
    lam_issue::Float64 # client demand estimate the grant was sized for
    issue_idx::Int
    expiry_idx::Int
    switch_idx::Int    # index at which the client stopped using it (0 = still in use)
    release_idx::Int   # index from which the center may free its unused part (0 = not yet known)
end

mutable struct Client
    mu::Float64        # mean demand rate (before pattern and drift)
    phase::Float64     # daily phase shift [min]
    logdrift::Float64  # OU state of slow drift
    grant::Int         # active grant id (0 = none)
    tokens::Float64    # token bucket for local pacing
    used::Float64      # client-counted spend on the active grant
    cum_spend::Float64 # client-counted cumulative spend
    request_idx::Int   # index at which a pending request was sent (0 = none)
    lam_own::Float64   # client's own EWMA of its demand rate
end

mutable struct Center
    grants::Vector{Grant}
    unsettled::Vector{Int}    # grants that may still add spend not yet visible in Y
    lam::Vector{Float64}      # per-client demand rate estimate
    lam_long::Float64         # ~1 day EWMA of total demand (fallback for unseen profile bins)
    initialized::Bool
    beta_hat::Float64         # estimate of ΔDB / Δclient-reported
    ew_dY::Float64
    ew_dC::Float64
    prev_Y::Float64
    prev_C::Float64
    profile::Vector{Float64}  # learned daily profile of total demand rate
    seen::Vector{Bool}
    cur_bin::Int
    bin_acc::Float64
    bin_cnt::Int
    level::Float64            # current demand / learned profile (catches unknown weekly effects)
end

Center(cfg::Config) = Center(Grant[], Int[], zeros(cfg.n_clients), 0.0, false,
                             1.0, 0.0, 0.0, 0.0, 0.0,
                             zeros(cfg.profile_bins), falses(cfg.profile_bins), 0, 0.0, 0, 1.0)

# ---------------------------------------------------------------- world

"Daily × weekly demand shape (not normalized). The center never sees this function."
function base_pattern(cfg::Config, t, phase)
    daily = 1 + cfg.daily_amp * sin(2π * (t + phase) / DAY - π / 2)
    weekly = mod(floor(Int, t / DAY), 7) >= 5 ? 1 - cfg.weekly_amp : 1.0
    daily * weekly
end

shock(cfg::Config, t) = cfg.shock_start <= t < cfg.shock_start + cfg.shock_length ? cfg.shock_factor : 1.0

# ---------------------------------------------------------------- center: safety

"""
    exposure(g, Ccli, s, now, cfg)

Upper bound on DB spend from grant `g` that may not be included in the DB value yet.
`s` is the latest index guaranteed to be included in the observed DB value (now − D_max).
Returns 0 when the grant is settled (nothing more can appear in the DB from it).
"""
function exposure(g::Grant, Ccli::Matrix{Float64}, s::Int, now::Int, cfg::Config)
    sw = g.switch_idx == 0 ? typemax(Int) : g.switch_idx
    released = g.release_idx != 0 && now >= g.release_idx
    released && s >= sw && return 0.0
    cfg.exposure_mode == :full && return cfg.beta_max * g.amount
    i = g.client
    used_safe = s > g.issue_idx ? Ccli[i, min(s, sw)] - Ccli[i, g.issue_idx] : 0.0
    if released
        used_final = Ccli[i, sw] - Ccli[i, g.issue_idx]
        return cfg.beta_max * (used_final - used_safe)
    end
    cfg.beta_max * (g.amount - used_safe)
end

# ---------------------------------------------------------------- center: estimation

bin_of(cfg::Config, t) = floor(Int, mod(t, DAY) / (DAY / cfg.profile_bins)) + 1

"Fold one step of reported per-client demand `d` (step starting at time `t`) into the estimates."
function update_demand!(c::Center, cfg::Config, d::AbstractVector, t)
    tot = sum(d) / cfg.dt
    if !c.initialized
        c.lam .= d ./ cfg.dt
        c.lam_long = tot
        c.initialized = true
    else
        α = cfg.dt / cfg.ewma_minutes
        @. c.lam += α * (d / cfg.dt - c.lam)
        c.lam_long += cfg.dt / DAY * (tot - c.lam_long)
    end
    b = bin_of(cfg, t)
    if cfg.level_minutes > 0 && c.seen[b] && c.profile[b] > 0
        c.level += cfg.dt / cfg.level_minutes * (tot / c.profile[b] - c.level)
    end
    if b != c.cur_bin
        if c.cur_bin != 0 && c.bin_cnt > 0
            p, avg = c.cur_bin, c.bin_acc / c.bin_cnt
            c.profile[p] = c.seen[p] ? (1 - cfg.profile_alpha) * c.profile[p] + cfg.profile_alpha * avg : avg
            c.seen[p] = true
        end
        c.cur_bin, c.bin_acc, c.bin_cnt = b, 0.0, 0
    end
    c.bin_acc += tot
    c.bin_cnt += 1
    nothing
end

"Track β̂ = ΔY / ΔC, where C is client-reported spend aligned to the assumed DB delay."
function update_beta!(c::Center, cfg::Config, Y, C_aligned)
    α = cfg.dt / cfg.beta_ewma_minutes
    c.ew_dY += α * ((Y - c.prev_Y) - c.ew_dY)
    c.ew_dC += α * ((C_aligned - c.prev_C) - c.ew_dC)
    c.prev_Y, c.prev_C = Y, C_aligned
    c.ew_dC > 1e-9 && (c.beta_hat = c.ew_dY / c.ew_dC)
    nothing
end

"Expected total demand over [t, T] from the learned daily profile, scaled by the current level."
function remaining_demand(c::Center, cfg::Config, t, T)
    binlen = DAY / cfg.profile_bins
    total = 0.0
    while t < T - 1e-9
        b = bin_of(cfg, t)
        tend = min((floor(t / binlen) + 1) * binlen, T)
        total += (c.seen[b] ? c.level * c.profile[b] : c.lam_long) * (tend - t)
        t = tend
    end
    total
end

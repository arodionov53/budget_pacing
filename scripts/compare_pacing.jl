# Side-by-side run of pacing strategies on the same world (same seed).
#   julia scripts/compare_pacing.jl
# Writes out/pacing_<name>.csv (time series) and prints per-strategy metrics as markdown.

include(joinpath(@__DIR__, "..", "src", "BudgetPacing.jl"))
using .BudgetPacing
using Printf, Statistics

strategies = [
    "uniform"           => Config(strategy = :uniform),
    "adaptive_nolevel"  => Config(level_minutes = 0.0),
    "adaptive"          => Config(),
]

hour(t) = mod(t, 1440) / 60
day(t) = floor(Int, t / 1440)          # 0 = Monday
pct(x, q) = sort(x)[clamp(round(Int, q * (length(x) - 1)) + 1, 1, length(x))]

println("| strategy | p median (Tue–Fri) | p 5–95 % (Tue–Fri) | served at peak 11–13 h | served at night 2–4 h | p median (weekend) | minutes at max rate | grants/min | denied | done before T (h) |")
println("|---|---|---|---|---|---|---|---|---|---|")
for (name, cfg) in strategies
    s, ts = simulate(cfg)
    write_csv(joinpath(@__DIR__, "..", "out", "pacing_$name.csv"), ts)
    wk = [1 <= day(t) <= 4 for t in ts.t]
    we = [day(t) >= 5 && t < cfg.T - cfg.finish_buffer for t in ts.t]
    peak = wk .& [11 <= hour(t) < 13 for t in ts.t]
    night = wk .& [2 <= hour(t) < 4 for t in ts.t]
    served(m) = sum(ts.spend[m]) / sum(ts.demand[m])
    pw = ts.p[wk]
    sat = count(>=(1 + cfg.demand_headroom - 1e-9), ts.p[ts.t .< cfg.T - cfg.finish_buffer]) * cfg.record_every
    @printf("| %s | %.2f | %.2f–%.2f | %.0f %% | %.0f %% | %.2f | %d | %.2f | %d | %.1f |\n",
            name, median(pw), pct(pw, 0.05), pct(pw, 0.95), 100served(peak), 100served(night),
            median(ts.p[we]), sat, s.grants_per_min, s.denied, s.finish_early / 60)
end

# Late demand drop (last 12 h at 30 %): where the level factor and the margin matter.
println("\n| strategy (last-12h shock 30 %) | spend % of B | p median in the last 12 h |")
println("|---|---|---|")
for (name, cfg0) in strategies
    cfg = with(cfg0; shock_start = 6.5 * 1440.0, shock_length = 720.0, shock_factor = 0.3)
    s, ts = simulate(cfg)
    write_csv(joinpath(@__DIR__, "..", "out", "pacing_shock_$name.csv"), ts)
    last = [cfg.shock_start <= t < cfg.T - cfg.finish_buffer for t in ts.t]
    @printf("| %s | %.2f | %.2f |\n", name, 100s.spend_ratio, median(ts.p[last]))
end

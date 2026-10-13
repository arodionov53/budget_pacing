"""
    run_mc(cfg; seeds=1:50) -> Vector of summaries

Monte Carlo: the same configuration with different random seeds.
"""
function run_mc(cfg::Config; seeds = 1:50)
    results = Vector{Any}(undef, length(seeds))
    Threads.@threads for j in eachindex(seeds)
        results[j] = first(simulate(with(cfg; seed = seeds[j]); record = false))
    end
    results
end

"Copy of `cfg` with some fields replaced."
function with(cfg::Config; kwargs...)
    vals = Dict{Symbol,Any}(f => getfield(cfg, f) for f in fieldnames(Config))
    for (k, v) in kwargs
        haskey(vals, k) || error("unknown Config field $k")
        vals[k] = v
    end
    Config(; vals...)
end

quantile_sorted(x, q) = x[clamp(round(Int, q * (length(x) - 1)) + 1, 1, length(x))]

"Aggregate Monte Carlo summaries into one NamedTuple."
function aggregate(results)
    sr = sort([r.spend_ratio for r in results])
    (
        runs = length(results),
        spend_mean = mean(sr),
        spend_p05 = quantile_sorted(sr, 0.05),
        spend_min = first(sr),
        spend_max = last(sr),
        over_runs = count(r -> r.overspend > 0, results),
        over_max = maximum(r.overspend for r in results),
        possible = mean(r.possible_ratio for r in results),
        grants_per_min = mean(r.grants_per_min for r in results),
        utilization = mean(r.utilization for r in results),
        est_err = mean(r.est_err for r in results),
        naive_err = mean(r.naive_err for r in results),
        alert_runs = count(r -> !isnan(r.alert_first), results),
        # hours before T at which 99.9% of B was reached (NaN: never); 0 is ideal, large = idle tail
        T_minus_finish_h = (fin = [r.finish_early for r in results if !isnan(r.finish_early)];
                            isempty(fin) ? NaN : mean(fin) / 60),
    )
end

function print_header(io::IO = stdout)
    @printf(io, "%-30s %8s %8s %8s %8s %6s %9s %8s %7s %7s %7s %6s %8s\n",
            "scenario", "spend%", "p05%", "min%", "max%", "over", "possible", "grant/m", "util%",
            "Ŝerr‰", "Yerr‰", "alert", "T-fin,h")
    println(io, "-"^137)
end

function print_row(io::IO, name, a)
    @printf(io, "%-30s %8.3f %8.3f %8.3f %8.3f %6d %9.2f %8.2f %7.1f %7.3f %7.3f %6d %8.1f\n",
            name, 100a.spend_mean, 100a.spend_p05, 100a.spend_min, 100a.spend_max, a.over_runs,
            a.possible, a.grants_per_min, 100a.utilization, 1000a.est_err, 1000a.naive_err, a.alert_runs,
            a.T_minus_finish_h)
end
print_row(name, a) = print_row(stdout, name, a)

function print_summary(io::IO, s)
    for (k, v) in pairs(s)
        @printf(io, "  %-16s %s\n", k, v isa AbstractFloat ? @sprintf("%.6g", v) : string(v))
    end
end
print_summary(s) = print_summary(stdout, s)

"Write a time series NamedTuple as CSV (no external packages)."
function write_csv(path::AbstractString, ts)
    open(path, "w") do io
        println(io, join(keys(ts), ','))
        for j in eachindex(ts.t)
            println(io, join((ts[k][j] for k in keys(ts)), ','))
        end
    end
    path
end

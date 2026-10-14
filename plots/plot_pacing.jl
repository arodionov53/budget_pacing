# Compare pacing strategies from scripts/compare_pacing.jl output.
#   julia --project=plots plots/plot_pacing.jl        → out/pacing.png

using Plots

const OUT = joinpath(@__DIR__, "..", "out")
const NAMES = [("uniform", "uniform", "#eb6834"),
               ("adaptive_nolevel", "adaptive, no level factor", "#1baf7a"),
               ("adaptive", "adaptive (default)", "#2a78d6")]
const C_GRAY = "#8a8984"
const B, T = 1.0e6, 7 * 1440.0     # match Config() defaults

function read_ts(path)
    lines = readlines(path)
    header = Symbol.(split(lines[1], ','))
    data = [parse.(Float64, split(l, ',')) for l in lines[2:end] if !isempty(l)]
    Dict(h => [row[j] for row in data] for (j, h) in enumerate(header))
end
smooth(x, w) = [sum(@view x[max(1, i - w ÷ 2):min(end, i + w ÷ 2)]) / length(max(1, i - w ÷ 2):min(length(x), i + w ÷ 2)) for i in eachindex(x)]

base = Dict(n => read_ts(joinpath(OUT, "pacing_$n.csv")) for (n, _, _) in NAMES)
shock = Dict(n => read_ts(joinpath(OUT, "pacing_shock_$n.csv")) for (n, _, _) in NAMES)

default(fontfamily = "Helvetica", linewidth = 2, grid = true, gridalpha = 0.15, framestyle = :axes,
        legend = :topright, foreground_color_legend = nothing, background_color_legend = nothing,
        tickfontsize = 8, guidefontsize = 9, legendfontsize = 8, titlefontsize = 10, titlelocation = :left,
        left_margin = 4Plots.mm, bottom_margin = 3Plots.mm)

days(ts) = ts[:t] ./ 1440

p1 = plot(title = "a) Throttle p (granted rate / demand), baseline", ylabel = "p", xlabel = "day",
          xlims = (0, 7), xticks = 0:7, ylims = (0, 1.6))
for (n, lbl, c) in NAMES
    plot!(p1, days(base[n]), base[n][:p]; color = c, label = lbl, linewidth = n == "adaptive" ? 2 : 1.5)
end

ts = base["adaptive"]
p2 = plot(days(ts), smooth(ts[:demand], 6); color = C_GRAY, linewidth = 1, label = "demand (if all served)",
          title = "b) Spend rate, Tue–Thu (1 h average)", ylabel = "money / min", xlabel = "day",
          xlims = (1, 4), xticks = 1:4, legend = :topleft)
for (n, lbl, c) in NAMES[[1, 3]]
    plot!(p2, days(base[n]), smooth(base[n][:spend], 6); color = c, label = lbl)
end

p3 = plot(title = "c) Ahead of the linear plan, baseline", ylabel = "S/B − t/T  (% points)", xlabel = "day",
          xlims = (0, 7), xticks = 0:7, legend = :bottomleft)
hline!(p3, [0]; color = C_GRAY, linestyle = :dash, linewidth = 1, label = nothing)
for (n, lbl, c) in NAMES
    d = base[n]
    plot!(p3, days(d), 100 .* (d[:S] ./ B .- d[:t] ./ T); color = c, label = lbl)
end

p4 = plot(title = "d) Last two days with demand at 30 % in the last 12 h", ylabel = "S / B", xlabel = "day",
          xlims = (5, 7), xticks = 5:0.5:7, ylims = (0.8, 1.005), legend = :bottomright)
vspan!(p4, [6.5, 7]; color = C_GRAY, alpha = 0.12, label = "demand shock")
for (n, lbl, c) in NAMES
    d = shock[n]
    plot!(p4, days(d), d[:S] ./ B; color = c, label = lbl)
end

fig = plot(p1, p2, p3, p4; layout = (4, 1), size = (1000, 1250), dpi = 120)
savefig(fig, joinpath(OUT, "pacing.png"))
println("plot → ", normpath(joinpath(OUT, "pacing.png")))

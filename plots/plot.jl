# Plot a time series written by scripts/run.jl.
#   julia --project=plots plots/plot.jl [out/run.csv] [out/run.png]

using Plots

const C_BLUE, C_ORANGE, C_AQUA, C_GRAY = "#2a78d6", "#eb6834", "#1baf7a", "#8a8984"

function read_ts(path)
    lines = readlines(path)
    header = Symbol.(split(lines[1], ','))
    data = [parse.(Float64, split(l, ',')) for l in lines[2:end] if !isempty(l)]
    Dict(h => [row[j] for row in data] for (j, h) in enumerate(header))
end

"Centered moving average over `w` samples (spend and demand are noisy per sample)."
smooth(x, w) = [sum(@view x[max(1, i - w ÷ 2):min(end, i + w ÷ 2)]) / length(max(1, i - w ÷ 2):min(length(x), i + w ÷ 2)) for i in eachindex(x)]

src = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "..", "out", "run.csv")
dst = length(ARGS) >= 2 ? ARGS[2] : replace(src, r"\.csv$" => ".png")
ts = read_ts(src)

days = ts[:t] ./ 1440
B = 1.0e6                          # matches Config().B; change if you change B
w = 6                              # 6 samples × 10 min = 1 h smoothing

default(fontfamily = "Helvetica", linewidth = 2, grid = true, gridalpha = 0.15, framestyle = :axes,
        legend = :topleft, foreground_color_legend = nothing, background_color_legend = nothing,
        xticks = 0:1:7, xlims = (0, 7), tickfontsize = 8, guidefontsize = 9, legendfontsize = 8,
        titlefontsize = 10, titlelocation = :left, left_margin = 4Plots.mm, bottom_margin = 2Plots.mm)

p1 = plot(days, days ./ 7; color = C_GRAY, linestyle = :dash, linewidth = 1, label = "linear reference",
          title = "Cumulative spend (fraction of B)", ylabel = "S / B", ylims = (0, 1.02))
plot!(p1, days, ts[:Y] ./ B; color = C_ORANGE, label = "observed Y (delayed DB)")
plot!(p1, days, ts[:S] ./ B; color = C_BLUE, label = "true S")
plot!(p1, days, (ts[:Y] .+ ts[:E]) ./ B; color = C_AQUA, linewidth = 1, label = "committed Y + E (hard-cap side)")

p2 = plot(days, smooth(ts[:demand], w); color = C_GRAY, linewidth = 1, label = "demand (if all served)",
          title = "Spend rate per minute (1 h average)", ylabel = "money / min")
plot!(p2, days, smooth(ts[:spend], w); color = C_BLUE, label = "actual spend")
plot!(p2, days, smooth(ts[:rstar], w); color = C_ORANGE, linewidth = 1, label = "target r*")

p3 = plot(days, ts[:p]; color = C_BLUE, label = nothing, ylims = (0, 1.6),
          title = "Effective throttle p (granted rate / demand)", ylabel = "p")
hline!(p3, [1.0]; color = C_GRAY, linestyle = :dash, linewidth = 1, label = nothing)

p4 = plot(days, 1000 .* abs.(ts[:Shat] .- ts[:S]) ./ B; color = C_BLUE, label = "nowcast |Ŝ − S|",
          title = "Estimation error (‰ of B)", ylabel = "‰", xlabel = "day")
plot!(p4, days, 1000 .* abs.(ts[:Y] .- ts[:S]) ./ B; color = C_ORANGE, linewidth = 1, label = "raw delayed |Y − S|")

fig = plot(p1, p2, p3, p4; layout = (4, 1), size = (1000, 1100), dpi = 120)
savefig(fig, dst)
println("plot → ", normpath(dst))

# Single run with the default (or modified) configuration.
#   julia scripts/run.jl
# Writes the time series to out/run.csv (plot it with plots/plot.jl).

include(joinpath(@__DIR__, "..", "src", "BudgetPacing.jl"))
using .BudgetPacing

cfg = Config()               # e.g. Config(strategy = :uniform, D = 120.0)
summary, ts = simulate(cfg)

println("Single run, seed = $(cfg.seed)")
print_summary(summary)
path = write_csv(joinpath(@__DIR__, "..", "out", "run.csv"), ts)
println("time series → ", normpath(path))

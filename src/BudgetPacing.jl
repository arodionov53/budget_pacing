"""
Budget pacing simulator: a center spends budget `B` over period `T` by issuing grants
(local budget + expiry) to clients with noisy demand, observing true spend from a
central DB with delay `D`. Hard cap: total DB spend never exceeds `B`.
"""
module BudgetPacing

using Random, Statistics, Printf

export Config, simulate, run_mc, with, aggregate, print_header, print_row, print_summary, write_csv

include("config.jl")
include("model.jl")
include("simulate.jl")
include("analysis.jl")

end

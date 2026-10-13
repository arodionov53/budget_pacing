# Strategy comparison used in MODEL.md. Prints markdown tables.
#   julia -t auto scripts/strategies.jl [runs] > out/strategies.md

include(joinpath(@__DIR__, "..", "src", "BudgetPacing.jl"))
using .BudgetPacing
using Printf

const RUNS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 40
agg(cfg) = aggregate(run_mc(cfg; seeds = 1:RUNS))
fmt_h(x) = isnan(x) ? "–" : @sprintf("%.1f", x)
spend_cell(a) = @sprintf("%.2f / %.2f", 100a.spend_mean, 100a.spend_min)

base = Config()
vol = with(base; drift_sigma = 0.8, drift_tau = 120.0)
worlds = [
    "baseline"          => base,
    "demand ×1.15"      => with(base; demand_ratio = 1.15),
    "day-4 shock 20%"   => with(base; shock_start = 3 * 1440.0, shock_length = 1440.0, shock_factor = 0.2),
    "last-12h shock 30%"=> with(base; shock_start = 6.5 * 1440.0, shock_length = 720.0, shock_factor = 0.3),
    "demand ×0.9"       => with(base; demand_ratio = 0.9),
]

"Cross table: rows = variants (kwargs applied to every world), columns = worlds; cell = f(aggregate)."
function cross(title, variants, worlds; cell = spend_cell, note = "cell: mean % / min % of B spent")
    println("\n### $title\n\n_$(note); $RUNS runs per cell_\n")
    println("| variant | ", join(first.(worlds), " | "), " |")
    println("|---|", repeat("---|", length(worlds)))
    for (vname, kw) in variants
        cells = [cell(agg(with(w; kw...))) for (_, w) in worlds]
        println("| $vname | ", join(cells, " | "), " |")
    end
end

"Detail table: one row per configuration."
function detail(title, rows)
    println("\n### $title\n\n_$RUNS runs per row_\n")
    println("| variant | spend mean % | min % | runs over B | max over (‰ B) | grants/min | util % | Ŝ err ‰ | Y err ‰ | done before T (h) | alert runs |")
    println("|---|---|---|---|---|---|---|---|---|---|---|")
    for (name, cfg) in rows
        a = agg(cfg)
        @printf("| %s | %.3f | %.3f | %d | %.3f | %.2f | %.1f | %.3f | %.3f | %s | %d |\n",
                name, 100a.spend_mean, 100a.spend_min, a.over_runs, 1000a.over_max / cfg.B,
                a.grants_per_min, 100a.utilization, 1000a.est_err, 1000a.naive_err,
                fmt_h(a.T_minus_finish_h), a.alert_runs)
    end
end

println("## Simulation results ($RUNS seeds per configuration)")

cross("A. Pacing strategy", [
    "uniform"                    => (strategy = :uniform,),
    "adaptive, no level factor"  => (level_minutes = 0.0,),
    "adaptive (default)"         => (;),
    "uniform, no margin"         => (strategy = :uniform, finish_buffer = 0.0, forecast_haircut = 0.0),
    "adaptive, no margin"        => (finish_buffer = 0.0, forecast_haircut = 0.0),
], worlds)

margin_worlds = worlds[[1, 2, 4]]
margin_variants = [
    "none (0 h, 0)"     => (finish_buffer = 0.0, forecast_haircut = 0.0),
    "buffer 6 h"        => (finish_buffer = 360.0, forecast_haircut = 0.0),
    "1 h + haircut 0.05"=> (finish_buffer = 60.0, forecast_haircut = 0.05),
    "1 h + haircut 0.1" => (finish_buffer = 60.0, forecast_haircut = 0.1),
    "1 h + haircut 0.2 (default)" => (finish_buffer = 60.0, forecast_haircut = 0.2),
    "1 h + haircut 0.3" => (finish_buffer = 60.0, forecast_haircut = 0.3),
]
cross("B. Planning margin — spend", margin_variants, margin_worlds)
cross("B'. Planning margin — idle tail", margin_variants, margin_worlds;
      cell = a -> fmt_h(a.T_minus_finish_h), note = "cell: hours before T at which 99.9 % of B was spent (– = never)")

detail("C. Grant duration τ", [
    "τmax = 15 min"            => with(base; tau_max = 15.0),
    "τmax = 60 min (default)"  => base,
    "τmax = 240 min"           => with(base; tau_max = 240.0),
    "τ = 240 fixed"            => with(base; tau_min = 240.0, tau_max = 240.0),
    "volatile, τmax = 15"      => with(vol; tau_max = 15.0),
    "volatile, τmax = 60"      => vol,
    "volatile, τ = 240 fixed"  => with(vol; tau_min = 240.0, tau_max = 240.0),
])

client_worlds = [
    "volatile, τ=240"        => with(vol; tau_min = 240.0, tau_max = 240.0),
    "5 volatile, τ=240"      => with(vol; n_clients = 5, tau_min = 240.0, tau_max = 240.0),
    "volatile, demand ×1.2"  => with(vol; demand_ratio = 1.2),
    "last-12h shock 30%"     => worlds[4][2],
]
cross("D. Client behaviour (re-grant, return)", [
    "re-grant + partial return (default)" => (;),
    "no partial return"                   => (return_keep_factor = 0.0,),
    "no re-grant"                         => (regrant_threshold = Inf,),
    "no return at all"                    => (return_unused = false,),
], client_worlds)

cross("E. Exposure accounting", [
    "reported counters (default)" => (;),
    "full grant amounts"          => (exposure_mode = :full,),
], [worlds[1], client_worlds[1], client_worlds[2]])

detail("F. Delay compensation (nowcast)", [
    "D = 30, nowcast"      => base,
    "D = 30, pace on Y"    => with(base; nowcast = :none),
    "D = 120, nowcast"     => with(base; D = 120.0),
    "D = 120, pace on Y"   => with(base; D = 120.0, nowcast = :none),
    "D = 240, nowcast"     => with(base; D = 240.0),
    "D = 240, pace on Y"   => with(base; D = 240.0, nowcast = :none),
    "D = 240, last-12h shock, nowcast"   => with(worlds[4][2]; D = 240.0),
    "D = 240, last-12h shock, pace on Y" => with(worlds[4][2]; D = 240.0, nowcast = :none),
])

detail("G. Safety assumptions", [
    "D = 30 ± 15, D_max = 45 (correct)"   => with(base; D_jitter = 15.0),
    "D = 30 ± 15, D_max = 30 (too small)" => with(base; D_jitter = 15.0, D_max = 30.0),
    "β = 1.02, β_max = 1.06 (correct)"    => base,
    "β = 1.08, β_max = 1.06 (too small)"  => with(base; beta_true = 1.08),
    "noise cv = 1.5"                      => with(base; noise_cv = 1.5),
])

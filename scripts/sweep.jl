# Monte Carlo comparison of design choices and stress scenarios.
#   julia -t auto scripts/sweep.jl [runs]
# Columns:
#   spend%     mean final DB spend / B          p05/min/max  distribution over runs
#   over       runs that exceeded B (must be 0 when assumptions hold)
#   possible   all demand served / B (≥1 means B is reachable in principle)
#   grant/m    grants issued per minute (center load)
#   util%      client spend / granted amount
#   Ŝerr‰      mean |Ŝ − S|/B of the nowcast;  Yerr‰ same for the raw delayed DB value
#   alert      runs where the feasibility alert fired

include(joinpath(@__DIR__, "..", "src", "BudgetPacing.jl"))
using .BudgetPacing

runs = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 40
base = Config()
vol = with(base; drift_sigma = 0.8, drift_tau = 120.0)     # client demand swings strongly within hours

scenarios = [
    # --- policy choices ---
    "baseline (adaptive)"          => base,
    "uniform pacing"               => with(base; strategy = :uniform),
    "adaptive, no level corr."     => with(base; level_minutes = 0.0),
    "no finish buffer, no haircut" => with(base; finish_buffer = 0.0, forecast_haircut = 0.0),
    "haircut 0.05"                 => with(base; forecast_haircut = 0.05),
    "no early return"              => with(base; return_unused = false),
    "no re-grant on demand rise"   => with(base; regrant_threshold = Inf),
    "exposure = full grants"       => with(base; exposure_mode = :full),
    "τmax = 240 min"               => with(base; tau_max = 240.0),
    "τmax = 15 min"                => with(base; tau_max = 15.0),
    "h = 0.2, burst = 2 min"       => with(base; demand_headroom = 0.2, burst_minutes = 2.0),
    # --- volatile clients, long grants: where re-grant and return matter ---
    "volatile, τ=240"              => with(vol; tau_min = 240.0, tau_max = 240.0),
    "volatile, τ=240, no return"   => with(vol; tau_min = 240.0, tau_max = 240.0, return_unused = false),
    "volatile, τ=240, no re-grant" => with(vol; tau_min = 240.0, tau_max = 240.0, regrant_threshold = Inf),
    "5 vol. clients, τ=240"        => with(vol; n_clients = 5, tau_min = 240.0, tau_max = 240.0),
    "5 vol. clients, τ=240, no ret"=> with(vol; n_clients = 5, tau_min = 240.0, tau_max = 240.0, return_unused = false),
    # --- delay ---
    "D = 120 min"                  => with(base; D = 120.0),
    "D = 30 ± 15 (D_max known)"    => with(base; D_jitter = 15.0),
    "D = 30 ± 15 (D_max = 30!)"    => with(base; D_jitter = 15.0, D_max = 30.0),   # wrong assumption
    # --- demand ---
    "noise cv = 1.5"               => with(base; noise_cv = 1.5),
    "demand ratio 1.15"            => with(base; demand_ratio = 1.15),
    "demand ratio 0.9 (short)"     => with(base; demand_ratio = 0.9),
    "shock: day 4 at 20%"          => with(base; shock_start = 3 * 1440.0, shock_length = 1440.0, shock_factor = 0.2),
    "shock: day 4 at 20%, uniform" => with(base; shock_start = 3 * 1440.0, shock_length = 1440.0, shock_factor = 0.2,
                                          strategy = :uniform),
    "shock: last 12 h at 30%"      => with(base; shock_start = 6.5 * 1440.0, shock_length = 720.0, shock_factor = 0.3),
    "shock: last 12 h, haircut .05"=> with(base; shock_start = 6.5 * 1440.0, shock_length = 720.0, shock_factor = 0.3,
                                          forecast_haircut = 0.05),
    # --- DB / client mismatch ---
    "β_true = 1.08 > β_max!"       => with(base; beta_true = 1.08),                 # wrong assumption
]

println("Monte Carlo: $runs runs per scenario, $(Threads.nthreads()) threads\n")
print_header()
for (name, cfg) in scenarios
    print_row(name, aggregate(run_mc(cfg; seeds = 1:runs)))
end

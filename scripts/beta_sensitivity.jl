# Sensitivity of results to β (DB amount = β × client-counted amount).
#   julia -t auto scripts/beta_sensitivity.jl [runs] > out/beta_sensitivity.md

include(joinpath(@__DIR__, "..", "src", "BudgetPacing.jl"))
using .BudgetPacing
using Printf

const RUNS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 40
fmt_h(x) = isnan(x) ? "–" : @sprintf("%.1f", x)
safe_max(b, noise) = b * (1 + 3noise)            # tight but valid bound for clipped noise

function table(title, rows)
    println("\n### $title\n")
    println("| β_true | β_noise | β_max | spend mean % | min % | runs over B | max over (‰ B) | Ŝ err ‰ | β̂ end | done before T (h) |")
    println("|---|---|---|---|---|---|---|---|---|---|")
    for cfg in rows
        res = run_mc(cfg; seeds = 1:RUNS)
        a = aggregate(res)
        bhat = sum(r.beta_hat for r in res) / length(res)
        @printf("| %.2f | %.2f | %.3f | %.3f | %.3f | %d | %.3f | %.3f | %.4f | %s |\n",
                cfg.beta_true, cfg.beta_noise, cfg.beta_max, 100a.spend_mean, 100a.spend_min,
                a.over_runs, 1000a.over_max / cfg.B, 1000a.est_err, bhat, fmt_h(a.T_minus_finish_h))
    end
end

base = Config()
big = with(base; drift_sigma = 0.8, drift_tau = 120.0, n_clients = 5, tau_min = 240.0, tau_max = 240.0)

println("## Sensitivity to β ($RUNS seeds per row)")

table("1. Level of β (bound valid: β_max = β_true·(1+3·noise))",
      [with(base; beta_true = b, beta_max = safe_max(b, 0.01)) for b in (0.8, 0.9, 1.0, 1.02, 1.1, 1.2, 1.5)])

table("2. Per-transaction noise of β (β_true = 1, bound valid)",
      [with(base; beta_true = 1.0, beta_noise = s, beta_max = safe_max(1.0, s)) for s in (0.0, 0.01, 0.03, 0.1, 0.3)])

table("3. Conservative bound, baseline (β_true = 1 exactly)",
      [with(base; beta_true = 1.0, beta_noise = 0.0, beta_max = m) for m in (1.0, 1.05, 1.1, 1.2, 1.5, 2.0)])

table("4. Conservative bound, 5 large volatile clients, τ = 240 (β_true = 1 exactly)",
      [with(big; beta_true = 1.0, beta_noise = 0.0, beta_max = m) for m in (1.0, 1.05, 1.1, 1.2, 1.5, 2.0)])

table("5. Bound too small (β_max = 1, i.e. center assumes f = 1)",
      [with(base; beta_true = b, beta_noise = 0.0, beta_max = 1.0) for b in (1.0, 1.01, 1.02, 1.05, 1.1, 1.2)])

table("6. Bound too small, 5 large volatile clients, τ = 240 (β_max = 1)",
      [with(big; beta_true = b, beta_noise = 0.0, beta_max = 1.0) for b in (1.0, 1.01, 1.02, 1.05, 1.1, 1.2)])

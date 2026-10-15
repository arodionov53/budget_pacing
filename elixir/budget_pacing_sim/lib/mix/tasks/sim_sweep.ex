defmodule Mix.Tasks.Sim.Sweep do
  @moduledoc """
  Monte Carlo sweep over design choices and stress scenarios.
  Mirrors scripts/sweep.jl from the Julia simulator.

      mix sim.sweep [--runs N] [--format text|markdown]

  Options:
    --runs     Seeds per scenario (default: 10)
    --format   Output format: "text" (default, aligned columns) or "markdown"
  """
  use Mix.Task

  alias BudgetPacingSim.{Config, Analysis}

  @shortdoc "Monte Carlo sweep over scenarios"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [runs: :integer, format: :string]
      )

    runs = opts[:runs] || 10
    format = opts[:format] || "text"

    base = Config.new()
    vol = Config.with(base, drift_sigma: 0.8, drift_tau: 120.0)

    scenarios = [
      # --- policy choices ---
      {"baseline (adaptive)", base},
      {"uniform pacing", Config.with(base, strategy: :uniform)},
      {"adaptive, no level corr.", Config.with(base, level_minutes: 0.0)},
      {"no buffer, no haircut", Config.with(base, finish_buffer: 0.0, forecast_haircut: 0.0)},
      {"haircut 0.05", Config.with(base, forecast_haircut: 0.05)},
      {"no early return", Config.with(base, return_unused: false)},
      {"no re-grant on demand rise", Config.with(base, regrant_threshold: 1.0e18)},
      {"exposure = full grants", Config.with(base, exposure_mode: :full)},
      {"tau_max = 240 min", Config.with(base, tau_max: 240.0)},
      {"tau_max = 15 min", Config.with(base, tau_max: 15.0)},
      {"h=0.2, burst=2 min", Config.with(base, demand_headroom: 0.2, burst_minutes: 2.0)},
      # --- volatile clients, long grants ---
      {"volatile, tau=240", Config.with(vol, tau_min: 240.0, tau_max: 240.0)},
      {"volatile, tau=240, no ret", Config.with(vol, tau_min: 240.0, tau_max: 240.0, return_unused: false)},
      {"volatile, tau=240, no regr", Config.with(vol, tau_min: 240.0, tau_max: 240.0, regrant_threshold: 1.0e18)},
      {"5 vol. clients, tau=240", Config.with(vol, n_clients: 5, tau_min: 240.0, tau_max: 240.0)},
      {"5 vol, tau=240, no ret", Config.with(vol, n_clients: 5, tau_min: 240.0, tau_max: 240.0, return_unused: false)},
      # --- delay ---
      {"D = 120 min", Config.with(base, d_delay: 120.0)},
      {"D = 30 +/- 15 (known)", Config.with(base, d_jitter: 15.0)},
      {"D = 30 +/- 15 (Dmax=30!)", Config.with(base, d_jitter: 15.0, d_max: 30.0)},
      # --- demand ---
      {"noise cv = 1.5", Config.with(base, noise_cv: 1.5)},
      {"demand ratio 1.15", Config.with(base, demand_ratio: 1.15)},
      {"demand ratio 0.9 (short)", Config.with(base, demand_ratio: 0.9)},
      {"shock: day4 at 20%", Config.with(base, shock_start: 3 * 1440.0, shock_length: 1440.0, shock_factor: 0.2)},
      {"shock: day4 20%, uniform", Config.with(base, shock_start: 3 * 1440.0, shock_length: 1440.0, shock_factor: 0.2, strategy: :uniform)},
      {"shock: last 12h at 30%", Config.with(base, shock_start: 6.5 * 1440.0, shock_length: 720.0, shock_factor: 0.3)},
      {"shock: last12h, hc=.05", Config.with(base, shock_start: 6.5 * 1440.0, shock_length: 720.0, shock_factor: 0.3, forecast_haircut: 0.05)},
      # --- DB / client mismatch ---
      {"beta=1.08 > beta_max!", Config.with(base, beta_true: 1.08)},
    ]

    seeds = 1..runs
    total = length(scenarios)

    IO.puts("Monte Carlo: #{runs} runs per scenario\n")

    case format do
      "markdown" ->
        IO.puts("| scenario | spend% | p05% | min% | max% | over | possible | grant/m | util% | Serr‰ | Yerr‰ | alert | T-fin,h |")
        IO.puts("|---|---|---|---|---|---|---|---|---|---|---|---|---|")

        Enum.with_index(scenarios, 1)
        |> Enum.each(fn {{name, cfg}, idx} ->
          IO.write(:stderr, "[#{idx}/#{total}] #{name}...\n")
          a = Analysis.run_mc(cfg, seeds) |> Analysis.aggregate()
          finish = if a.t_minus_finish_h, do: :erlang.float_to_binary(a.t_minus_finish_h, decimals: 1), else: "–"
          IO.puts("| #{name} | #{"~.3f" |> :io_lib.format([100 * a.spend_mean])} | #{"~.3f" |> :io_lib.format([100 * a.spend_p05])} | #{"~.3f" |> :io_lib.format([100 * a.spend_min])} | #{"~.3f" |> :io_lib.format([100 * a.spend_max])} | #{a.over_runs} | #{"~.2f" |> :io_lib.format([a.possible])} | #{"~.2f" |> :io_lib.format([a.grants_per_min])} | #{"~.1f" |> :io_lib.format([100 * a.utilization])} | #{"~.3f" |> :io_lib.format([1000 * a.est_err])} | #{"~.3f" |> :io_lib.format([1000 * a.naive_err])} | #{a.alert_runs} | #{finish} |")
        end)

      _ ->
        IO.puts(Analysis.detail_header())

        Enum.with_index(scenarios, 1)
        |> Enum.each(fn {{name, cfg}, idx} ->
          IO.write(:stderr, "[#{idx}/#{total}] #{name}...\n")
          a = Analysis.run_mc(cfg, seeds) |> Analysis.aggregate()
          IO.puts(Analysis.detail_row(name, a))
        end)
    end
  end
end

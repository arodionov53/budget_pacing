defmodule Mix.Tasks.Sim.Compare do
  @moduledoc """
  Side-by-side run of pacing strategies on the same seed.
  Mirrors scripts/compare_pacing.jl from the Julia simulator.

      mix sim.compare [--seed N] [--out-dir path]

  Options:
    --seed      Random seed (default: 1)
    --out-dir   Directory for CSV output (default: out/)
  """
  use Mix.Task

  alias BudgetPacingSim.{Config, Clock, Analysis}

  @shortdoc "Compare pacing strategies side by side"

  @strategies [
    {"uniform", strategy: :uniform},
    {"adaptive_nolevel", level_minutes: 0.0},
    {"adaptive", []}
  ]

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [seed: :integer, out_dir: :string]
      )

    seed = opts[:seed] || 1
    out_dir = opts[:out_dir] || "out"
    File.mkdir_p!(out_dir)

    # ---- Baseline runs ----
    IO.puts("## Strategy comparison (seed=#{seed})\n")
    IO.puts(table_header())
    IO.puts(table_sep())

    baseline_results =
      Enum.map(@strategies, fn {name, overrides} ->
        cfg = Config.new([{:seed, seed} | overrides])
        {summary, ts} = Clock.run(cfg)

        csv_path = Path.join(out_dir, "pacing_#{name}.csv")
        Analysis.write_csv(csv_path, ts)
        IO.write(:stderr, "  #{csv_path}\n")

        row = compute_metrics(name, summary, ts, cfg)
        IO.puts(format_row(row))

        {name, summary, ts, cfg}
      end)

    # ---- Shock runs (last 12h at 30%) ----
    IO.puts("\n## With last-12h shock at 30%\n")
    IO.puts("| strategy | spend % of B | p median in last 12h |")
    IO.puts("|---|---|---|")

    Enum.each(baseline_results, fn {name, _summary, _ts, base_cfg} ->
      cfg =
        Config.with(base_cfg,
          shock_start: 6.5 * 1440.0,
          shock_length: 720.0,
          shock_factor: 0.3
        )

      {summary, ts} = Clock.run(cfg)

      csv_path = Path.join(out_dir, "pacing_shock_#{name}.csv")
      Analysis.write_csv(csv_path, ts)
      IO.write(:stderr, "  #{csv_path}\n")

      # p median in the shock window (before finish buffer)
      shock_ps =
        ts
        |> Enum.filter(fn row ->
          row.t >= cfg.shock_start and row.t < cfg.t - cfg.finish_buffer
        end)
        |> Enum.map(& &1.p)

      p_med = if shock_ps == [], do: 0.0, else: median(shock_ps)

      IO.puts(
        "| #{name} | #{fmtf(100 * summary.spend_ratio, 2)} | #{fmtf(p_med, 2)} |"
      )
    end)

    IO.puts("\nCSV files written to #{out_dir}/")
  end

  # ---- Metrics ----

  defp compute_metrics(name, summary, ts, cfg) do
    day_fn = fn t -> Float.floor(t / 1440.0) |> trunc() end
    hour_fn = fn t -> :math.fmod(t, 1440.0) / 60.0 end

    # Weekday ticks (Tue-Fri = days 1-4)
    wk = Enum.filter(ts, fn r -> d = day_fn.(r.t); d >= 1 and d <= 4 end)
    we = Enum.filter(ts, fn r -> day_fn.(r.t) >= 5 and r.t < cfg.t - cfg.finish_buffer end)

    peak = Enum.filter(wk, fn r -> h = hour_fn.(r.t); h >= 11 and h < 13 end)
    night = Enum.filter(wk, fn r -> h = hour_fn.(r.t); h >= 2 and h < 4 end)

    served = fn rows ->
      spend_sum = Enum.sum(Enum.map(rows, & &1.spend))
      demand_sum = Enum.sum(Enum.map(rows, & &1.demand))
      if demand_sum > 0, do: spend_sum / demand_sum, else: 0.0
    end

    wk_ps = Enum.map(wk, & &1.p)
    we_ps = Enum.map(we, & &1.p)

    at_max =
      ts
      |> Enum.filter(fn r -> r.t < cfg.t - cfg.finish_buffer end)
      |> Enum.count(fn r -> r.p >= 1.0 + cfg.demand_headroom - 1.0e-9 end)

    at_max_minutes = at_max * cfg.record_every

    %{
      name: name,
      p_med_wk: median(wk_ps),
      p_05_wk: percentile(wk_ps, 0.05),
      p_95_wk: percentile(wk_ps, 0.95),
      served_peak: served.(peak),
      served_night: served.(night),
      p_med_we: median(we_ps),
      at_max_minutes: at_max_minutes,
      grants_per_min: summary.grants_per_min,
      denied: summary.denied,
      finish_h: if(summary.finish_early, do: summary.finish_early / 60.0, else: nil)
    }
  end

  # ---- Table formatting ----

  defp table_header do
    "| strategy | p median (Tue-Fri) | p 5-95% (Tue-Fri) | served at peak 11-13h | served at night 2-4h | p median (weekend) | min at max rate | grants/min | denied | done before T (h) |"
  end

  defp table_sep do
    "|---|---|---|---|---|---|---|---|---|---|"
  end

  defp format_row(r) do
    finish = if r.finish_h, do: fmtf(r.finish_h, 1), else: "–"

    "| #{r.name} | #{fmtf(r.p_med_wk, 2)} | #{fmtf(r.p_05_wk, 2)}–#{fmtf(r.p_95_wk, 2)} | #{fmti(100 * r.served_peak)} % | #{fmti(100 * r.served_night)} % | #{fmtf(r.p_med_we, 2)} | #{r.at_max_minutes} | #{fmtf(r.grants_per_min, 2)} | #{r.denied} | #{finish} |"
  end

  # ---- Helpers ----

  defp median([]), do: 0.0
  defp median(xs) do
    sorted = Enum.sort(xs)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    else
      Enum.at(sorted, mid)
    end
  end

  defp percentile([], _q), do: 0.0
  defp percentile(xs, q) do
    sorted = Enum.sort(xs)
    n = length(sorted)
    idx = max(1, min(round(q * (n - 1)) + 1, n))
    Enum.at(sorted, idx - 1)
  end

  defp fmtf(x, decimals) do
    :erlang.float_to_binary(x / 1, decimals: decimals)
  end

  defp fmti(x), do: round(x) |> Integer.to_string()
end

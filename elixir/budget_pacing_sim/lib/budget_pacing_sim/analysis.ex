defmodule BudgetPacingSim.Analysis do
  @moduledoc """
  Analysis utilities: Monte Carlo runs, aggregation, formatting, CSV export.
  Mirrors src/analysis.jl from the Julia simulator.
  """

  alias BudgetPacingSim.{Config, Clock}

  # ---------------------------------------------------------------- Monte Carlo

  @doc """
  Run the same configuration with different random seeds, in parallel (one run per
  scheduler). Returns a list of summary maps, in seed order.

  Each run seeds the RNG of the process it runs in and starts its own GenServers, so
  parallel runs don't share any state and give the same results as sequential ones.
  """
  def run_mc(%Config{} = cfg, seeds) do
    seeds
    |> Task.async_stream(
      fn seed ->
        {summary, _ts} = Clock.run(Config.with(cfg, seed: seed, record_every: 0))
        summary
      end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, summary} -> summary end)
  end

  # ---------------------------------------------------------------- Aggregation

  @doc """
  Aggregate a list of Monte Carlo summaries into one statistics map.
  Matches Julia's `aggregate()` in analysis.jl.
  """
  def aggregate(results) when is_list(results) and results != [] do
    sr = results |> Enum.map(& &1.spend_ratio) |> Enum.sort()
    n = length(sr)

    finish_times =
      results
      |> Enum.map(& &1.finish_early)
      |> Enum.reject(&is_nil/1)

    t_minus_finish_h =
      if finish_times == [] do
        nil
      else
        Enum.sum(finish_times) / length(finish_times) / 60.0
      end

    %{
      runs: n,
      spend_mean: mean(sr),
      spend_p05: quantile_sorted(sr, 0.05),
      spend_min: List.first(sr),
      spend_max: List.last(sr),
      over_runs: Enum.count(results, fn r -> r.overspend > 0 end),
      over_max: results |> Enum.map(& &1.overspend) |> Enum.max(),
      possible: mean(Enum.map(results, & &1.possible_ratio)),
      grants_per_min: mean(Enum.map(results, & &1.grants_per_min)),
      utilization: mean(Enum.map(results, & &1.utilization)),
      est_err: mean(Enum.map(results, & &1.est_err)),
      naive_err: mean(Enum.map(results, & &1.naive_err)),
      alert_runs: Enum.count(results, fn r -> r.alert_first != nil end),
      t_minus_finish_h: t_minus_finish_h
    }
  end

  # ---------------------------------------------------------------- Formatting

  @detail_sep String.duplicate("-", 137)

  @doc "Format a detail table header."
  def detail_header do
    cols = [
      pad_r("scenario", 30), pad_l("spend%", 8), pad_l("p05%", 8), pad_l("min%", 8),
      pad_l("max%", 8), pad_l("over", 6), pad_l("possible", 9), pad_l("grant/m", 8),
      pad_l("util%", 7), pad_l("Serr‰", 7), pad_l("Yerr‰", 7), pad_l("alert", 6),
      pad_l("T-fin,h", 8)
    ]

    Enum.join(cols, " ") <> "\n" <> @detail_sep
  end

  @doc "Format one detail row from a {name, aggregate} pair."
  def detail_row(name, a) do
    finish = if a.t_minus_finish_h, do: ff(a.t_minus_finish_h, 1), else: "–"

    cols = [
      pad_r(name, 30),
      pad_l(ff(100 * a.spend_mean, 3), 8),
      pad_l(ff(100 * a.spend_p05, 3), 8),
      pad_l(ff(100 * a.spend_min, 3), 8),
      pad_l(ff(100 * a.spend_max, 3), 8),
      pad_l(Integer.to_string(a.over_runs), 6),
      pad_l(ff(a.possible, 2), 9),
      pad_l(ff(a.grants_per_min, 2), 8),
      pad_l(ff(100 * a.utilization, 1), 7),
      pad_l(ff(1000 * a.est_err, 3), 7),
      pad_l(ff(1000 * a.naive_err, 3), 7),
      pad_l(Integer.to_string(a.alert_runs), 6),
      pad_l(finish, 8)
    ]

    Enum.join(cols, " ")
  end

  @doc "Format a spend-cell for cross tables: 'mean% / min%'."
  def spend_cell(a) do
    "#{ff(100 * a.spend_mean, 2)} / #{ff(100 * a.spend_min, 2)}"
  end

  @doc """
  Print a cross table (markdown) with rows = variants, columns = worlds.
  `variants`: [{name, keyword_overrides}]
  `worlds`: [{name, %Config{}}]
  `cell_fn`: aggregate -> string (default: spend_cell)
  """
  def cross_table(title, variants, worlds, opts \\ []) do
    runs = Keyword.get(opts, :runs, 10)
    cell_fn = Keyword.get(opts, :cell_fn, &spend_cell/1)

    header = "| variant | " <> Enum.map_join(worlds, " | ", &elem(&1, 0)) <> " |"
    sep = "|---|" <> String.duplicate("---|", length(worlds))

    rows =
      Enum.map(variants, fn {vname, kw} ->
        cells =
          Enum.map(worlds, fn {_wname, wcfg} ->
            cfg = Config.with(wcfg, kw)
            a = run_mc(cfg, 1..runs) |> aggregate()
            cell_fn.(a)
          end)

        "| #{vname} | " <> Enum.join(cells, " | ") <> " |"
      end)

    Enum.join(["### #{title}", "", header, sep | rows], "\n")
  end

  @doc """
  Print a detail table (aligned text) for a list of {name, config} rows.
  """
  def detail_table(title, rows, opts \\ []) do
    runs = Keyword.get(opts, :runs, 10)

    data_rows =
      Enum.map(rows, fn {name, cfg} ->
        a = run_mc(cfg, 1..runs) |> aggregate()
        detail_row(name, a)
      end)

    Enum.join(["### #{title}", "", detail_header() | data_rows], "\n")
  end

  # ---------------------------------------------------------------- CSV

  @ts_fields [:t, :s, :y, :s_hat, :e, :demand, :spend, :p, :beta_hat]

  @doc "Write a time-series (list of maps) to CSV."
  def write_csv(path, ts) do
    header = Enum.map_join(@ts_fields, ",", &Atom.to_string/1) <> "\n"

    rows =
      Enum.map(ts, fn row ->
        Enum.map_join(@ts_fields, ",", fn f -> "#{Map.fetch!(row, f)}" end) <> "\n"
      end)

    File.write!(path, [header | rows])
    path
  end

  # ---------------------------------------------------------------- Helpers

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp quantile_sorted(sorted, q) do
    n = length(sorted)
    idx = round(q * (n - 1)) + 1
    idx = max(1, min(idx, n))
    Enum.at(sorted, idx - 1)
  end

  defp ff(x, decimals), do: :erlang.float_to_binary(x / 1, decimals: decimals)
  defp pad_r(s, w), do: String.pad_trailing(to_string(s), w)
  defp pad_l(s, w), do: String.pad_leading(to_string(s), w)
end

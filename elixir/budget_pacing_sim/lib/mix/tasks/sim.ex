defmodule Mix.Tasks.Sim do
  @moduledoc """
  Run the budget pacing simulator.

      mix sim [--config path.toml] [--seed N] [--record path.csv] [--format json|table]

  Options:
    --config   Path to a TOML config file (default: use built-in defaults)
    --seed     Override the random seed (default: from config)
    --record   Write time-series to a CSV file
    --format   Output format: "json" (default) or "table" (human-readable)
  """
  use Mix.Task

  alias BudgetPacingSim.{Config, Clock, Analysis}

  @shortdoc "Run the budget pacing simulator"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [config: :string, seed: :integer, record: :string, format: :string]
      )

    cfg =
      case opts[:config] do
        nil -> Config.new()
        path -> Config.load!(path)
      end

    cfg =
      case opts[:seed] do
        nil -> cfg
        seed -> Config.with(cfg, seed: seed)
      end

    {summary, ts} = Clock.run(cfg)

    # Print summary
    case opts[:format] do
      "table" ->
        a = Analysis.aggregate([summary])
        IO.puts(Analysis.detail_header())
        IO.puts(Analysis.detail_row("seed=#{cfg.seed}", a))

      _ ->
        IO.puts(Jason.encode!(summary, pretty: true))
    end

    # Optionally write time-series CSV
    case opts[:record] do
      nil ->
        :ok

      path ->
        Analysis.write_csv(path, ts)
        IO.puts(:stderr, "Time series written to #{path}")
    end
  end
end

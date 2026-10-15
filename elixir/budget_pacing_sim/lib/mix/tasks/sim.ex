defmodule Mix.Tasks.Sim do
  @moduledoc """
  Run the budget pacing simulator.

      mix sim [--config path.toml] [--seed N] [--record path.csv]

  Options:
    --config   Path to a TOML config file (default: use built-in defaults)
    --seed     Override the random seed (default: from config)
    --record   Write time-series to a CSV file
  """
  use Mix.Task

  alias BudgetPacingSim.{Config, Clock}

  @shortdoc "Run the budget pacing simulator"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [config: :string, seed: :integer, record: :string]
      )

    cfg =
      case opts[:config] do
        nil -> Config.new()
        path -> Config.load!(path)
      end

    cfg =
      case opts[:seed] do
        nil -> cfg
        seed -> %Config{cfg | seed: seed}
      end

    {summary, ts} = Clock.run(cfg)

    # Print JSON summary to stdout
    json = Jason.encode!(summary, pretty: true)
    IO.puts(json)

    # Optionally write time-series CSV
    case opts[:record] do
      nil ->
        :ok

      path ->
        write_csv(path, ts)
        IO.puts(:stderr, "Time series written to #{path}")
    end
  end

  defp write_csv(path, ts) do
    header = "t,s,y,s_hat,e,demand,spend,p,beta_hat\n"

    rows =
      Enum.map(ts, fn row ->
        "#{row.t},#{row.s},#{row.y},#{row.s_hat},#{row.e},#{row.demand},#{row.spend},#{row.p},#{row.beta_hat}\n"
      end)

    File.write!(path, [header | rows])
  end
end

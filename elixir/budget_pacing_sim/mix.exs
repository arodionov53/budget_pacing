defmodule BudgetPacingSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :budget_pacing_sim,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {BudgetPacingSim.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"}
    ]
  end
end

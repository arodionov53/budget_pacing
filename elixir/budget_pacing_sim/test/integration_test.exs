defmodule BudgetPacingSim.IntegrationTest do
  use ExUnit.Case

  alias BudgetPacingSim.{Config, Clock}

  @moduletag timeout: 180_000

  describe "default config (adaptive, seed=1)" do
    test "full simulation matches expected ranges from Julia results" do
      cfg = Config.new()
      {summary, ts} = Clock.run(cfg)

      # Hard cap: never exceed B (Julia: 0 runs over B)
      assert summary.overspend == 0.0
      assert summary.spend_ratio <= 1.0

      # spend_ratio ≈ 1.0 (Julia: 100.000%)
      assert summary.spend_ratio > 0.999

      # grants_per_min (Julia: 2.38)
      assert summary.grants_per_min > 2.2
      assert summary.grants_per_min < 2.6

      # utilization (Julia: 89.9%)
      assert summary.utilization > 0.85
      assert summary.utilization < 0.95

      # nowcast is far more accurate than the raw delayed Y (Julia: 0.099‰ vs 2.976‰)
      assert summary.est_err < summary.naive_err / 10

      # Time series should have 1008 entries
      assert length(ts) == 1008
    end
  end

  describe "uniform strategy" do
    test "full simulation with uniform pacing" do
      cfg = Config.new(strategy: :uniform)
      {summary, _ts} = Clock.run(cfg)

      # Hard cap: never exceed B
      assert summary.overspend == 0.0
      assert summary.spend_ratio <= 1.0

      # spend_ratio ≈ 1.0 (Julia: 100.000%)
      assert summary.spend_ratio > 0.99

      # grants_per_min (Julia: 2.51)
      assert summary.grants_per_min > 2.2
      assert summary.grants_per_min < 2.8
    end
  end
end

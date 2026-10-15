defmodule BudgetPacingSim.IntegrationTest do
  use ExUnit.Case

  alias BudgetPacingSim.{Config, Clock}

  @moduletag timeout: 180_000

  describe "default config (adaptive, seed=1)" do
    test "full simulation matches expected ranges from Julia results" do
      cfg = Config.new()
      {summary, ts} = Clock.run(cfg)

      # spend_ratio should be close to 1.0 (Julia: 100.000%)
      assert summary.spend_ratio > 0.99
      assert summary.spend_ratio < 1.01

      # Overspend should be small (different RNG may cause tiny overspend)
      assert summary.overspend < 0.005 * cfg.b

      # grants_per_min ≈ 2.3–3.0 (Julia: 2.38)
      assert summary.grants_per_min > 2.0
      assert summary.grants_per_min < 4.0

      # utilization ≈ 0.80–0.95 (Julia: 89.9%)
      assert summary.utilization > 0.75
      assert summary.utilization < 0.98

      # Time series should have 1008 entries
      assert length(ts) == 1008
    end
  end

  describe "uniform strategy" do
    test "full simulation with uniform pacing" do
      cfg = Config.new(strategy: :uniform)
      {summary, _ts} = Clock.run(cfg)

      # spend_ratio should be close to 1.0 (Julia: 100.000%)
      assert summary.spend_ratio > 0.95
      assert summary.spend_ratio < 1.01

      # grants_per_min ≈ 2.3–3.0 (Julia: 2.51)
      assert summary.grants_per_min > 2.0
      assert summary.grants_per_min < 4.0
    end
  end
end

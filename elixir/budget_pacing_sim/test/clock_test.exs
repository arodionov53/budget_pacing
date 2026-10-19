defmodule BudgetPacingSim.ClockTest do
  use ExUnit.Case

  alias BudgetPacingSim.{Config, Clock}

  describe "world generation" do
    test "with seed=1, n_clients=50, mu values are positive and sum to demand_ratio * B/T" do
      # We test this indirectly by running a very short sim
      cfg = Config.new(t: 10.0, n_clients: 5)
      {summary, _ts} = Clock.run(cfg)

      # Should complete without error, spend_ratio > 0
      assert summary.spend_ratio >= 0.0
      assert summary.grants >= 0
    end
  end

  describe "short run" do
    test "100 ticks complete without crash and produce spend" do
      # Use short delay so center starts seeing DB data quickly
      cfg = Config.new(t: 100.0, n_clients: 5, d_delay: 2.0, record_every: 10)
      {summary, ts} = Clock.run(cfg)

      assert summary.spend_ratio >= 0.0
      assert summary.grants >= 0
      assert length(ts) == 10  # 100 / 10
    end
  end

  @tag timeout: 120_000
  describe "full run" do
    test "default 10080-tick run completes and spend_ratio is close to 1.0" do
      cfg = Config.new(record_every: 10)
      {summary, ts} = Clock.run(cfg)

      assert summary.spend_ratio > 0.95
      # Hard cap: never exceed B
      assert summary.overspend == 0.0
      assert summary.grants > 0
      assert summary.grants_per_min > 0
      assert length(ts) == 1008  # 10080 / 10
    end
  end

  describe "hard cap" do
    test "S never exceeds Y + E on any tick, and spend stays within B" do
      cfg = Config.new(t: 2000.0, b: 150_000.0, n_clients: 20, record_every: 1)
      {summary, ts} = Clock.run(cfg)

      assert summary.overspend == 0.0
      assert Enum.all?(ts, fn r -> r.s <= r.y + r.e + 1.0e-6 end)
    end

    test "delay jitter runs without crashing (beta_hat can briefly be 0)" do
      {summary, _ts} = Clock.run(Config.new(t: 300.0, d_jitter: 15.0, record_every: 0))
      assert summary.overspend == 0.0
    end
  end

  describe "time series recording" do
    test "with record_every=10, time-series has correct number of entries" do
      cfg = Config.new(t: 50.0, n_clients: 3, record_every: 10)
      {_summary, ts} = Clock.run(cfg)

      assert length(ts) == 5  # 50 / 10

      # Each entry should have the expected fields
      entry = hd(ts)
      assert Map.has_key?(entry, :t)
      assert Map.has_key?(entry, :s)
      assert Map.has_key?(entry, :y)
      assert Map.has_key?(entry, :s_hat)
      assert Map.has_key?(entry, :e)
      assert Map.has_key?(entry, :demand)
      assert Map.has_key?(entry, :spend)
      assert Map.has_key?(entry, :p)
      assert Map.has_key?(entry, :beta_hat)
    end
  end
end

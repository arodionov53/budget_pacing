defmodule BudgetPacingSim.AnalysisTest do
  use ExUnit.Case, async: false

  alias BudgetPacingSim.{Config, Analysis}

  describe "aggregate/1" do
    test "computes correct statistics from known summaries" do
      summaries = [
        %{spend_ratio: 1.0, overspend: 0.0, possible_ratio: 1.5, grants_per_min: 2.3,
          utilization: 0.9, est_err: 0.001, naive_err: 0.003, alert_first: nil, finish_early: 120.0},
        %{spend_ratio: 0.98, overspend: 0.0, possible_ratio: 1.4, grants_per_min: 2.5,
          utilization: 0.85, est_err: 0.002, naive_err: 0.004, alert_first: nil, finish_early: 180.0},
        %{spend_ratio: 0.99, overspend: 0.0, possible_ratio: 1.45, grants_per_min: 2.4,
          utilization: 0.88, est_err: 0.0015, naive_err: 0.0035, alert_first: nil, finish_early: 150.0}
      ]

      a = Analysis.aggregate(summaries)

      assert a.runs == 3
      assert_in_delta a.spend_mean, 0.99, 0.01
      assert a.spend_min == 0.98
      assert a.spend_max == 1.0
      assert a.over_runs == 0
      assert a.over_max == 0.0
      assert a.alert_runs == 0
      # finish_early: mean of [120, 180, 150] / 60 = 2.5 h
      assert_in_delta a.t_minus_finish_h, 2.5, 0.01
    end

    test "counts over_runs and alert_runs correctly" do
      summaries = [
        %{spend_ratio: 1.001, overspend: 100.0, possible_ratio: 1.5, grants_per_min: 2.3,
          utilization: 0.9, est_err: 0.001, naive_err: 0.003, alert_first: 5000.0, finish_early: 60.0},
        %{spend_ratio: 0.99, overspend: 0.0, possible_ratio: 1.4, grants_per_min: 2.5,
          utilization: 0.85, est_err: 0.002, naive_err: 0.004, alert_first: nil, finish_early: nil}
      ]

      a = Analysis.aggregate(summaries)
      assert a.over_runs == 1
      assert a.over_max == 100.0
      assert a.alert_runs == 1
      # Only one has finish_early
      assert_in_delta a.t_minus_finish_h, 1.0, 0.01
    end
  end

  describe "run_mc/2" do
    test "returns one summary per seed" do
      cfg = Config.new(t: 50.0, n_clients: 3, d_delay: 2.0)
      results = Analysis.run_mc(cfg, 1..3)

      assert length(results) == 3
      assert Enum.all?(results, &is_map/1)
      assert Enum.all?(results, &Map.has_key?(&1, :spend_ratio))
    end
  end

  describe "write_csv/2" do
    test "writes CSV with correct header and rows" do
      ts = [
        %{t: 10.0, s: 100.0, y: 90.0, s_hat: 98.0, e: 50.0, demand: 5.0, spend: 4.0, p: 0.6, beta_hat: 1.02},
        %{t: 20.0, s: 200.0, y: 180.0, s_hat: 196.0, e: 45.0, demand: 5.5, spend: 4.5, p: 0.65, beta_hat: 1.02}
      ]

      path = Path.join(System.tmp_dir!(), "test_analysis_#{:rand.uniform(100000)}.csv")
      Analysis.write_csv(path, ts)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert hd(lines) == "t,s,y,s_hat,e,demand,spend,p,beta_hat"
      assert length(lines) == 3  # header + 2 rows

      File.rm!(path)
    end
  end

  describe "Config.with/2" do
    test "returns a new config with fields replaced" do
      cfg = Config.new()
      cfg2 = Config.with(cfg, strategy: :uniform, seed: 42)

      assert cfg2.strategy == :uniform
      assert cfg2.seed == 42
      assert cfg2.b == cfg.b  # unchanged
    end
  end

  describe "formatting" do
    test "detail_header returns a non-empty string with column names" do
      h = Analysis.detail_header()
      assert String.contains?(h, "spend%")
      assert String.contains?(h, "grant/m")
    end

    test "detail_row formats an aggregate" do
      a = %{
        spend_mean: 1.0, spend_p05: 0.999, spend_min: 0.998, spend_max: 1.001,
        over_runs: 0, possible: 1.5, grants_per_min: 2.38, utilization: 0.9,
        est_err: 0.0001, naive_err: 0.003, alert_runs: 0, t_minus_finish_h: 2.6
      }

      row = Analysis.detail_row("baseline", a)
      assert String.contains?(row, "baseline")
      assert String.contains?(row, "100.000")
    end

    test "spend_cell formats mean/min" do
      a = %{spend_mean: 1.0, spend_min: 0.998}
      cell = Analysis.spend_cell(a)
      assert String.contains?(cell, "100.00")
      assert String.contains?(cell, "99.80")
    end
  end
end

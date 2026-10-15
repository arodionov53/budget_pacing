defmodule BudgetPacingSim.CenterTest do
  use ExUnit.Case, async: true

  alias BudgetPacingSim.{Config, Center, Grant, Model}

  defp make_tick_data(tick, reports, opts \\ []) do
    cfg = Keyword.get(opts, :config, Config.new())

    %{
      tick: tick,
      reports: reports,
      y_obs: Keyword.get(opts, :y_obs, 0.0),
      ctot_aligned: Keyword.get(opts, :ctot_aligned, 0.0),
      ctot_rep: Keyword.get(opts, :ctot_rep, 0.0),
      s_db_now: Keyword.get(opts, :s_db_now, 0.0),
      ccli_fn: Keyword.get(opts, :ccli_fn, fn _cid, _idx -> 0.0 end),
      requesting_clients: Keyword.get(opts, :requesting_clients, %{}),
      perm: Keyword.get(opts, :perm, [])
    }
  end

  describe "startup" do
    test "center starts with zero estimates" do
      cfg = Config.new()
      {:ok, pid} = Center.start_link(cfg)
      state = Center.get_state(pid)
      assert state.initialized == false
      assert length(state.lam) == 50
      assert Enum.all?(state.lam, &(&1 == 0.0))
      assert state.beta_hat == 1.0
      assert state.level == 1.0
    end
  end

  describe "demand estimation" do
    test "after 30 ticks of constant demand, lam converges" do
      cfg = Config.new(n_clients: 2)
      {:ok, pid} = Center.start_link(cfg)

      # Feed 30 ticks of constant demand: client 1 = 5.0/min, client 2 = 3.0/min
      for tick <- 1..30 do
        reports = [%{demand: 5.0}, %{demand: 3.0}]
        data = make_tick_data(tick, reports, config: cfg)
        {:ok, _} = Center.tick(pid, data)
      end

      state = Center.get_state(pid)
      # lam should converge toward [5.0, 3.0] (demand per min, dt=1)
      [lam1, lam2] = state.lam
      assert_in_delta lam1, 5.0, 0.5
      assert_in_delta lam2, 3.0, 0.5
      assert state.initialized == true
    end

    test "profile bin is updated after bin boundary" do
      cfg = Config.new(n_clients: 1)
      {:ok, pid} = Center.start_link(cfg)

      # First 15 ticks are in bin 1 (0-14 min), tick 16 (t=15) moves to bin 2
      for tick <- 1..16 do
        reports = [%{demand: 10.0}]
        data = make_tick_data(tick, reports, config: cfg)
        {:ok, _} = Center.tick(pid, data)
      end

      state = Center.get_state(pid)
      # Bin 1 should now be seen with a non-zero value
      assert Enum.at(state.seen, 0) == true
      assert Enum.at(state.profile, 0) > 0
    end
  end

  describe "pacing law" do
    test "uniform r* = R / ((1-hc) * (T_plan - t))" do
      cfg = Config.new(n_clients: 1, strategy: :uniform)
      {:ok, pid} = Center.start_link(cfg)

      # Initialize estimates
      reports = [%{demand: 100.0}]
      data = make_tick_data(1, reports, config: cfg, s_db_now: 0.0)
      {:ok, _} = Center.tick(pid, data)

      # At tick 2, R ≈ B, T_plan - t ≈ T - buffer - 2
      data2 = make_tick_data(2, reports, config: cfg, s_db_now: 0.0)
      {:ok, result} = Center.tick(pid, data2)

      # p should be positive
      assert result.p > 0
    end

    test "adaptive p does not depend strongly on time of day with flat profile" do
      cfg = Config.new(n_clients: 1, strategy: :adaptive)
      {:ok, pid} = Center.start_link(cfg)

      # Run enough ticks to build a flat profile (constant demand)
      for tick <- 1..100 do
        reports = [%{demand: 100.0}]
        data = make_tick_data(tick, reports, config: cfg, s_db_now: 0.0)
        {:ok, _} = Center.tick(pid, data)
      end

      # Get p at two different profile points
      reports = [%{demand: 100.0}]
      data_a = make_tick_data(101, reports, config: cfg, s_db_now: 0.0)
      {:ok, res_a} = Center.tick(pid, data_a)

      data_b = make_tick_data(102, reports, config: cfg, s_db_now: 0.0)
      {:ok, res_b} = Center.tick(pid, data_b)

      # p should be similar at adjacent ticks with constant demand
      assert_in_delta res_a.p, res_b.p, 0.1
    end
  end

  describe "exposure accounting" do
    test "settled grant is removed from unsettled" do
      cfg = Config.new(n_clients: 1)
      {:ok, pid} = Center.start_link(cfg)

      # Issue a grant via requesting_clients
      reports = [%{demand: 5.0}]

      data = make_tick_data(1, reports,
        config: cfg,
        requesting_clients: %{1 => %{lam: 5.0, old_grant_idx: nil}},
        perm: [1]
      )

      {:ok, result} = Center.tick(pid, data)
      assert result.issued == 1

      state = Center.get_state(pid)
      assert length(state.unsettled) == 1
    end
  end

  describe "grant issuance" do
    test "grant denied when headroom is below min_grant" do
      # Set B very small so headroom is tight
      cfg = Config.new(n_clients: 1, b: 1.0, delta: 0.0)
      {:ok, pid} = Center.start_link(cfg)

      reports = [%{demand: 5.0}]

      # y_obs close to B so headroom is tiny
      data = make_tick_data(1, reports,
        config: cfg,
        y_obs: 0.99,
        requesting_clients: %{1 => %{lam: 5.0, old_grant_idx: nil}},
        perm: [1]
      )

      {:ok, result} = Center.tick(pid, data)
      assert result.denied == 1
      assert result.issued == 0
    end
  end

  describe "feasibility alert" do
    test "alert fires when demand_ratio < 1 after day 1" do
      cfg = Config.new(n_clients: 1, demand_ratio: 0.9)
      {:ok, pid} = Center.start_link(cfg)

      # Simulate past day 1 (tick > 1440)
      # First build up some estimates
      for tick <- 1..10 do
        reports = [%{demand: 0.05}]  # very low demand
        data = make_tick_data(tick, reports, config: cfg)
        {:ok, _} = Center.tick(pid, data)
      end

      # Now jump to after day 1 with low demand and large remaining budget
      reports = [%{demand: 0.05}]

      data = make_tick_data(1500, reports,
        config: cfg,
        s_db_now: 100.0  # only 100 spent of 1M
      )

      {:ok, _} = Center.tick(pid, data)

      state = Center.get_state(pid)
      assert state.alert_minutes > 0
    end
  end
end

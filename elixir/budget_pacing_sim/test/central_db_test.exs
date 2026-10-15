defmodule BudgetPacingSim.CentralDBTest do
  use ExUnit.Case, async: true

  alias BudgetPacingSim.{Config, CentralDB}

  setup do
    cfg = Config.new(n_clients: 3)
    {:ok, pid} = CentralDB.start_link(cfg)
    %{pid: pid, cfg: cfg}
  end

  describe "init" do
    test "starts and initial values are zero", %{pid: pid} do
      assert CentralDB.ctot(pid, 0) == 0.0
      assert CentralDB.lookup(pid, 1, 0) == 0.0
      assert CentralDB.lookup(pid, 2, 0) == 0.0
    end
  end

  describe "record_spend" do
    test "after two ticks, s_db has 3 entries with correct cumulative sums", %{pid: pid} do
      # Tick 1: client 1 spends 10 (client) / 10.2 (db), client 2 spends 5 / 5.1
      :ok = CentralDB.record_spend(pid, 1, [{1, 10.0, 10.2}, {2, 5.0, 5.1}])
      # Tick 2: client 1 spends 8 / 8.16, client 3 spends 3 / 3.06
      :ok = CentralDB.record_spend(pid, 2, [{1, 8.0, 8.16}, {3, 3.0, 3.06}])

      # Check cumulative DB spend: 0, 15.3, 26.52
      y0 = CentralDB.observe(pid, 2, 0, 0)
      # With d_ticks=0, jitter=0, we see the latest entry
      # size=3, target = 3-1-0-0 = 2
      assert_in_delta y0, 10.2 + 5.1 + 8.16 + 3.06, 0.01

      # Check per-client cumulative
      assert CentralDB.lookup(pid, 1, 0) == 0.0
      assert_in_delta CentralDB.lookup(pid, 1, 1), 10.0, 0.01
      assert_in_delta CentralDB.lookup(pid, 1, 2), 18.0, 0.01

      assert CentralDB.lookup(pid, 2, 0) == 0.0
      assert_in_delta CentralDB.lookup(pid, 2, 1), 5.0, 0.01
      # Client 2 had no spend in tick 2, carries forward
      assert_in_delta CentralDB.lookup(pid, 2, 2), 5.0, 0.01

      assert_in_delta CentralDB.lookup(pid, 3, 2), 3.0, 0.01

      # ctot
      assert CentralDB.ctot(pid, 0) == 0.0
      assert_in_delta CentralDB.ctot(pid, 1), 15.0, 0.01
      assert_in_delta CentralDB.ctot(pid, 2), 26.0, 0.01
    end
  end

  describe "observe" do
    test "with D=3 ticks, observation at tick 5 returns s_db[2]", %{pid: pid} do
      # Record 5 ticks of spend (1.0 db each)
      for tick <- 1..5 do
        :ok = CentralDB.record_spend(pid, tick, [{1, 1.0, 1.0}])
      end

      # size=6 (indices 0..5). d_ticks=3, jitter=0: target = 5-3-0 = 2
      y = CentralDB.observe(pid, 5, 3, 0)
      # s_db[2] = 2.0 (cumulative after 2 ticks)
      assert_in_delta y, 2.0, 0.01
    end

    test "consecutive calls never decrease (monotonic)", %{pid: pid} do
      for tick <- 1..10 do
        :ok = CentralDB.record_spend(pid, tick, [{1, 1.0, 1.0}])
      end

      # First observe with small delay
      y1 = CentralDB.observe(pid, 10, 2, 0)
      # Second observe with bigger delay — should not go below y1
      y2 = CentralDB.observe(pid, 10, 5, 0)
      assert y2 >= y1
    end
  end
end

defmodule BudgetPacingSim.CentralDBTest do
  use ExUnit.Case, async: true

  alias BudgetPacingSim.{Config, CentralDB}

  # Ticks follow simulate.jl: index 1 is the initial value, the first recorded tick is 2.

  setup do
    cfg = Config.new(n_clients: 3)
    {:ok, pid} = CentralDB.start_link(cfg)
    %{pid: pid, cfg: cfg}
  end

  describe "init" do
    test "starts and initial values are zero", %{pid: pid} do
      assert CentralDB.ctot(pid, 1) == 0.0
      assert CentralDB.lookup(pid, 1, 1) == 0.0
      assert CentralDB.lookup(pid, 2, 1) == 0.0
      assert CentralDB.true_spend(pid) == 0.0
    end
  end

  describe "record_spend" do
    test "writes each tick at its own index with correct cumulative sums", %{pid: pid} do
      # Tick 2: client 1 spends 10 (client) / 10.2 (db), client 2 spends 5 / 5.1
      :ok = CentralDB.record_spend(pid, 2, [{1, 10.0, 10.2}, {2, 5.0, 5.1}])
      # Tick 3: client 1 spends 8 / 8.16, client 3 spends 3 / 3.06
      :ok = CentralDB.record_spend(pid, 3, [{1, 8.0, 8.16}, {3, 3.0, 3.06}])

      assert_in_delta CentralDB.true_spend(pid), 10.2 + 5.1 + 8.16 + 3.06, 0.01

      assert CentralDB.lookup(pid, 1, 1) == 0.0
      assert_in_delta CentralDB.lookup(pid, 1, 2), 10.0, 0.01
      assert_in_delta CentralDB.lookup(pid, 1, 3), 18.0, 0.01

      assert_in_delta CentralDB.lookup(pid, 2, 2), 5.0, 0.01
      # Client 2 had no spend in tick 3, carries forward
      assert_in_delta CentralDB.lookup(pid, 2, 3), 5.0, 0.01

      assert CentralDB.lookup(pid, 3, 2) == 0.0
      assert_in_delta CentralDB.lookup(pid, 3, 3), 3.0, 0.01

      assert CentralDB.ctot(pid, 1) == 0.0
      assert_in_delta CentralDB.ctot(pid, 2), 15.0, 0.01
      assert_in_delta CentralDB.ctot(pid, 3), 26.0, 0.01
    end

    test "a lookup at the current tick reads what was just recorded", %{pid: pid} do
      for tick <- 2..6, do: :ok = CentralDB.record_spend(pid, tick, [{1, 10.0, 10.0}])
      assert_in_delta CentralDB.lookup(pid, 1, 6), 50.0, 0.01
    end

    test "reading an unwritten index raises", %{cfg: cfg} do
      {:ok, pid} = GenServer.start(CentralDB, cfg)
      :ok = CentralDB.record_spend(pid, 2, [{1, 1.0, 1.0}])

      catch_exit(CentralDB.lookup(pid, 1, 3))
    end

    test "ticks out of order are rejected", %{cfg: cfg} do
      {:ok, pid} = GenServer.start(CentralDB, cfg)
      catch_exit(CentralDB.record_spend(pid, 5, [{1, 1.0, 1.0}]))
    end
  end

  describe "observe" do
    test "returns S at tick − D", %{pid: pid} do
      # After ticks 2..6 (1.0 each), index k holds k − 1.
      for tick <- 2..6, do: :ok = CentralDB.record_spend(pid, tick, [{1, 1.0, 1.0}])

      # now = 6, D = 3 ticks: index 3, cumulative 2.0
      assert_in_delta CentralDB.observe(pid, 6, 3, 0), 2.0, 0.01
    end

    test "consecutive calls never decrease (monotonic)", %{pid: pid} do
      for tick <- 2..11, do: :ok = CentralDB.record_spend(pid, tick, [{1, 1.0, 1.0}])

      y1 = CentralDB.observe(pid, 11, 2, 0)
      y2 = CentralDB.observe(pid, 11, 5, 0)
      assert y2 >= y1
    end

    test "true_spend does not shorten the delay of later observations", %{pid: pid} do
      for tick <- 2..41, do: :ok = CentralDB.record_spend(pid, tick, [{1, 1.0, 1.0}])

      y_before = CentralDB.observe(pid, 41, 30, 0)
      _ = CentralDB.true_spend(pid)
      :ok = CentralDB.record_spend(pid, 42, [{1, 1.0, 1.0}])
      y_after = CentralDB.observe(pid, 42, 30, 0)

      # Each tick adds 1.0, so the delayed view advances by exactly one tick.
      assert_in_delta y_after - y_before, 1.0, 0.01
    end
  end
end

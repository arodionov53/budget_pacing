defmodule BudgetPacingSim.ClientTest do
  use ExUnit.Case, async: true

  alias BudgetPacingSim.{Config, Client, Grant}

  @default_cfg Config.new(
                 n_clients: 1,
                 shock_start: :infinity,
                 noise_cv: 0.0,
                 drift_sigma: 0.0
               )

  describe "init" do
    test "starts with correct initial state" do
      {:ok, pid} = Client.start_link({1, 5.0, 0.0, 0.0, @default_cfg})
      state = Client.get_state(pid)
      assert state.id == 1
      assert state.mu == 5.0
      assert state.phase == 0.0
      assert state.grant == nil
      assert state.cum_spend == 0.0
      assert state.lam_own == 0.0
    end
  end

  describe "tick with grant" do
    test "spend <= demand, spend <= tokens, cum_spend updated" do
      cfg = @default_cfg
      {:ok, pid} = Client.start_link({1, 5.0, 0.0, 0.0, cfg})

      # Give a grant first
      grant = %Grant{
        client: 1, amount: 1000.0, rate: 3.0, lam_issue: 5.0,
        issue_tick: 1, expiry_tick: 100
      }
      {:ok, _} = Client.receive_grant(pid, grant, 1)

      # Tick with zero noise: demand = mu * base_pattern(0, 0) * dt
      # At t=0 (midnight), base_pattern ≈ 0.4 (daily_amp=0.6, sin(-pi/2)=-1 → 1-0.6=0.4)
      # But we set noise_cv=0 and drift_sigma=0, so d = mu * pattern * dt = 5 * 0.4 * 1 = 2.0
      {:ok, report} = Client.tick(pid, 1, {0.0, 0.0})

      # With rate=3.0, burst_minutes=5.0, tokens start at 0 then refill to min(0+3*1, 3*5)=3
      # spend = min(d, tokens, amount_left) = min(2.0, 3.0, 1000.0) = 2.0
      assert report.spend <= report.demand
      assert report.spend > 0.0
      assert report.cum_spend == report.spend
      assert_in_delta report.demand, 2.0, 0.1
      assert_in_delta report.spend, 2.0, 0.1
    end
  end

  describe "receive_grant" do
    test "receiving a grant while holding one sets switch_tick on old" do
      cfg = @default_cfg
      {:ok, pid} = Client.start_link({1, 5.0, 0.0, 0.0, cfg})

      old_grant = %Grant{
        client: 1, amount: 100.0, rate: 2.0, lam_issue: 5.0,
        issue_tick: 1, expiry_tick: 60
      }
      {:ok, _} = Client.receive_grant(pid, old_grant, 1)

      new_grant = %Grant{
        client: 1, amount: 200.0, rate: 3.0, lam_issue: 5.0,
        issue_tick: 10, expiry_tick: 70
      }
      {:ok, expired} = Client.receive_grant(pid, new_grant, 10)

      # Old grant should have switch_tick and release_tick set
      assert expired != nil
      assert expired.switch_tick == 10
      assert expired.release_tick == 10
      assert expired.amount == 100.0

      # New grant is active
      state = Client.get_state(pid)
      assert state.grant.amount == 200.0
      assert state.used == 0.0
    end
  end

  describe "grant expiry" do
    test "after expiry tick, client spend is 0 and grant is nil" do
      cfg = @default_cfg
      {:ok, pid} = Client.start_link({1, 5.0, 0.0, 0.0, cfg})

      grant = %Grant{
        client: 1, amount: 1000.0, rate: 3.0, lam_issue: 5.0,
        issue_tick: 1, expiry_tick: 3
      }
      {:ok, _} = Client.receive_grant(pid, grant, 1)

      # Tick at expiry: tick=3 >= expiry_tick=3 → expired
      {:ok, report} = Client.tick(pid, 3, {0.0, 0.0})
      assert report.spend == 0.0
      assert report.expired_grant != nil
      assert report.expired_grant.switch_tick == 3

      state = Client.get_state(pid)
      assert state.grant == nil
    end
  end
end

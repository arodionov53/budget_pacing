defmodule BudgetPacingSim.ModelTest do
  use ExUnit.Case, async: true

  alias BudgetPacingSim.{Config, Grant, Model}

  describe "Grant struct" do
    test "creates with required fields" do
      g = %Grant{
        client: 1,
        amount: 100.0,
        rate: 2.0,
        lam_issue: 3.0,
        issue_tick: 10,
        expiry_tick: 70
      }

      assert g.client == 1
      assert g.amount == 100.0
      assert g.rate == 2.0
      assert g.lam_issue == 3.0
      assert g.issue_tick == 10
      assert g.expiry_tick == 70
      assert g.switch_tick == nil
      assert g.release_tick == nil
    end

    test "switch_tick and release_tick can be set" do
      g = %Grant{
        client: 2,
        amount: 50.0,
        rate: 1.0,
        lam_issue: 1.5,
        issue_tick: 5,
        expiry_tick: 65,
        switch_tick: 30,
        release_tick: 30
      }

      assert g.switch_tick == 30
      assert g.release_tick == 30
    end
  end

  describe "base_pattern/3" do
    setup do
      %{cfg: Config.new()}
    end

    test "midnight (t=0, phase=0) gives minimum daily value", %{cfg: cfg} do
      # sin(2*pi*0/1440 - pi/2) = sin(-pi/2) = -1, so daily = 1 - 0.6 = 0.4
      val = Model.base_pattern(cfg, 0.0, 0.0)
      assert_in_delta val, 0.4, 0.01
    end

    test "6am (t=360) gives approximately 1.0 (midpoint)", %{cfg: cfg} do
      # sin(2*pi*360/1440 - pi/2) = sin(pi/2 - pi/2) = sin(0) = 0
      val = Model.base_pattern(cfg, 360.0, 0.0)
      assert_in_delta val, 1.0, 0.01
    end

    test "noon (t=720) gives maximum daily value", %{cfg: cfg} do
      # sin(2*pi*720/1440 - pi/2) = sin(pi - pi/2) = sin(pi/2) = 1
      val = Model.base_pattern(cfg, 720.0, 0.0)
      assert_in_delta val, 1.6, 0.01
    end

    test "weekend days are reduced by weekly_amp", %{cfg: cfg} do
      # Day 5 = Saturday (t = 5*1440 + 720 for Saturday noon)
      weekday_noon = Model.base_pattern(cfg, 720.0, 0.0)
      saturday_noon = Model.base_pattern(cfg, 5 * 1440.0 + 720.0, 0.0)
      assert_in_delta saturday_noon, weekday_noon * (1.0 - cfg.weekly_amp), 0.01
    end
  end

  describe "shock/2" do
    test "returns 1.0 when no shock (default)" do
      cfg = Config.new()
      assert Model.shock(cfg, 1000.0) == 1.0
    end

    test "returns shock_factor inside window" do
      cfg = Config.new(shock_start: 100.0, shock_length: 50.0, shock_factor: 0.3)
      assert Model.shock(cfg, 120.0) == 0.3
    end

    test "returns 1.0 outside window" do
      cfg = Config.new(shock_start: 100.0, shock_length: 50.0, shock_factor: 0.3)
      assert Model.shock(cfg, 50.0) == 1.0
      assert Model.shock(cfg, 150.0) == 1.0
    end

    test "returns 1.0 at exact end of window" do
      cfg = Config.new(shock_start: 100.0, shock_length: 50.0, shock_factor: 0.3)
      assert Model.shock(cfg, 150.0) == 1.0
    end
  end

  describe "exposure/5" do
    setup do
      cfg = Config.new()
      # Simple ccli_fn: client 1 has cumulative spend = index * 1.0
      ccli_fn = fn _client, idx -> idx * 1.0 end
      %{cfg: cfg, ccli_fn: ccli_fn}
    end

    test "grant in use: exposure = beta_max * (amount - used_safe)", %{cfg: cfg, ccli_fn: ccli_fn} do
      g = %Grant{
        client: 1, amount: 100.0, rate: 2.0, lam_issue: 2.0,
        issue_tick: 10, expiry_tick: 70
      }
      # s=20, now=30: used_safe = ccli(1, 20) - ccli(1, 10) = 20 - 10 = 10
      e = Model.exposure(g, ccli_fn, 20, 30, cfg)
      assert_in_delta e, cfg.beta_max * (100.0 - 10.0), 0.01
    end

    test "grant returned: exposure = beta_max * (used_final - used_safe)", %{cfg: cfg, ccli_fn: ccli_fn} do
      g = %Grant{
        client: 1, amount: 100.0, rate: 2.0, lam_issue: 2.0,
        issue_tick: 10, expiry_tick: 70, switch_tick: 25, release_tick: 25
      }
      # s=20, now=30: used_safe = ccli(1, 20) - ccli(1, 10) = 10
      # used_final = ccli(1, 25) - ccli(1, 10) = 15
      e = Model.exposure(g, ccli_fn, 20, 30, cfg)
      assert_in_delta e, cfg.beta_max * (15.0 - 10.0), 0.01
    end

    test "grant settled (s >= switch_tick, released): exposure = 0", %{cfg: cfg, ccli_fn: ccli_fn} do
      g = %Grant{
        client: 1, amount: 100.0, rate: 2.0, lam_issue: 2.0,
        issue_tick: 10, expiry_tick: 70, switch_tick: 25, release_tick: 25
      }
      # s=30 >= switch_tick=25, released, so settled
      e = Model.exposure(g, ccli_fn, 30, 35, cfg)
      assert e == 0.0
    end

    test ":full exposure mode returns beta_max * amount", %{ccli_fn: ccli_fn} do
      cfg = Config.new(exposure_mode: :full)
      g = %Grant{
        client: 1, amount: 100.0, rate: 2.0, lam_issue: 2.0,
        issue_tick: 10, expiry_tick: 70
      }
      e = Model.exposure(g, ccli_fn, 20, 30, cfg)
      assert_in_delta e, cfg.beta_max * 100.0, 0.01
    end
  end

  describe "bin_of/2" do
    test "t=0 maps to bin 1" do
      cfg = Config.new()
      assert Model.bin_of(cfg, 0.0) == 1
    end

    test "t=DAY-1 maps to last bin" do
      cfg = Config.new()
      assert Model.bin_of(cfg, 1439.0) == 96
    end

    test "t at first 15-min boundary maps to bin 2" do
      cfg = Config.new()
      assert Model.bin_of(cfg, 15.0) == 2
    end
  end

  describe "remaining_demand/7" do
    test "uniform profile returns level * (T - t)" do
      cfg = Config.new()
      # All bins seen, all profile values = 10.0, level = 1.0
      profile = List.duplicate(10.0, 96)
      seen = List.duplicate(true, 96)
      level = 1.0
      lam_long = 10.0

      result = Model.remaining_demand(cfg, profile, seen, level, lam_long, 0.0, 1440.0)
      # Should be level * 10.0 * 1440.0 = 14400.0
      assert_in_delta result, 14400.0, 1.0
    end

    test "unseen bins use lam_long" do
      cfg = Config.new()
      profile = List.duplicate(0.0, 96)
      seen = List.duplicate(false, 96)
      level = 1.0
      lam_long = 5.0

      result = Model.remaining_demand(cfg, profile, seen, level, lam_long, 0.0, 1440.0)
      assert_in_delta result, 5.0 * 1440.0, 1.0
    end
  end
end

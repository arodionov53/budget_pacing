defmodule BudgetPacingSim.ConfigTest do
  use ExUnit.Case, async: true

  alias BudgetPacingSim.Config

  describe "new/0 defaults match Julia config.jl" do
    setup do
      %{cfg: Config.new()}
    end

    test "budget & horizon", %{cfg: cfg} do
      assert cfg.b == 1.0e6
      assert cfg.t == 7 * 1440.0
      assert cfg.dt == 1.0
    end

    test "world: client demand", %{cfg: cfg} do
      assert cfg.n_clients == 50
      assert cfg.demand_ratio == 1.5
      assert cfg.size_spread == 0.8
      assert cfg.noise_cv == 0.5
      assert cfg.daily_amp == 0.6
      assert cfg.daily_phase_jitter == 60.0
      assert cfg.weekly_amp == 0.3
      assert cfg.drift_sigma == 0.15
      assert cfg.drift_tau == 360.0
      assert cfg.shock_start == :infinity
      assert cfg.shock_length == 0.0
      assert cfg.shock_factor == 1.0
    end

    test "world: central DB", %{cfg: cfg} do
      assert cfg.d_delay == 30.0
      assert cfg.d_jitter == 0.0
      assert cfg.beta_true == 1.02
      assert cfg.beta_noise == 0.01
      assert cfg.report_lag == 1.0
    end

    test "center's assumptions", %{cfg: cfg} do
      assert cfg.d_assumed == nil
      assert cfg.d_max == nil
      assert cfg.beta_max == 1.06
      assert cfg.delta == 0.0
      assert cfg.exposure_mode == :reported
      assert cfg.return_unused == true
      assert cfg.regrant_threshold == 0.3
      assert cfg.return_keep_factor == 2.0
    end

    test "policy: pacing", %{cfg: cfg} do
      assert cfg.strategy == :adaptive
      assert cfg.nowcast == :reports
      assert cfg.demand_headroom == 0.5
      assert cfg.ewma_minutes == 30.0
      assert cfg.beta_ewma_minutes == 240.0
      assert cfg.profile_bins == 96
      assert cfg.profile_alpha == 0.5
      assert cfg.level_minutes == 240.0
      assert cfg.finish_buffer == 60.0
      assert cfg.forecast_haircut == 0.2
    end

    test "policy: grants", %{cfg: cfg} do
      assert cfg.tau_frac == 0.01
      assert cfg.tau_min == 5.0
      assert cfg.tau_max == 60.0
      assert cfg.renew_lead == 3.0
      assert cfg.grant_latency == 1.0
      assert cfg.burst_minutes == 5.0
      assert cfg.min_grant == 1.0
      assert cfg.alert_tol == 0.001
    end

    test "run", %{cfg: cfg} do
      assert cfg.seed == 1
      assert cfg.record_every == 10
    end
  end

  describe "derived defaults" do
    test "d_assumed defaults to d_delay" do
      cfg = Config.new()
      assert Config.d_assumed(cfg) == 30.0
    end

    test "d_assumed uses explicit value when set" do
      cfg = Config.new(d_assumed: 45.0)
      assert Config.d_assumed(cfg) == 45.0
    end

    test "d_max defaults to d_delay + d_jitter" do
      cfg = Config.new(d_jitter: 15.0)
      assert Config.d_max(cfg) == 45.0
    end

    test "d_max uses explicit value when set" do
      cfg = Config.new(d_max: 60.0)
      assert Config.d_max(cfg) == 60.0
    end

    test "d_max with zero jitter equals d_delay" do
      cfg = Config.new()
      assert Config.d_max(cfg) == 30.0
    end
  end

  describe "load!/1" do
    test "partial TOML overrides only specified fields" do
      cfg = Config.load!("test/fixtures/partial.toml")
      assert cfg.b == 500_000.0
      assert cfg.n_clients == 20
      # all other fields are defaults
      assert cfg.t == 7 * 1440.0
      assert cfg.dt == 1.0
      assert cfg.demand_ratio == 1.5
      assert cfg.strategy == :adaptive
      assert cfg.seed == 1
    end

    test "raises on missing file" do
      assert_raise ArgumentError, fn ->
        Config.load!("nonexistent.toml")
      end
    end

    test "default_config.toml matches Config.new() for all set fields" do
      loaded = Config.load!("priv/default_config.toml")
      default = Config.new()

      # Fields present in the TOML (all except shock_start, d_assumed, d_max which are commented out)
      assert loaded.b == default.b
      assert loaded.t == default.t
      assert loaded.dt == default.dt
      assert loaded.n_clients == default.n_clients
      assert loaded.demand_ratio == default.demand_ratio
      assert loaded.strategy == default.strategy
      assert loaded.nowcast == default.nowcast
      assert loaded.exposure_mode == default.exposure_mode
      assert loaded.seed == default.seed
      assert loaded.record_every == default.record_every
      assert loaded.beta_max == default.beta_max
      assert loaded.forecast_haircut == default.forecast_haircut
      assert loaded.tau_max == default.tau_max
      # shock_start, d_assumed, d_max stay at defaults (nil/:infinity) since commented out
      assert loaded.shock_start == :infinity
      assert loaded.d_assumed == nil
      assert loaded.d_max == nil
    end
  end

  describe "validate!/1" do
    test "valid default config passes" do
      cfg = Config.new()
      assert Config.validate!(cfg) == cfg
    end

    test "invalid strategy raises" do
      cfg = Config.new(strategy: :greedy)

      assert_raise ArgumentError, ~r/strategy must be/, fn ->
        Config.validate!(cfg)
      end
    end

    test "invalid exposure_mode raises" do
      cfg = Config.new(exposure_mode: :bogus)

      assert_raise ArgumentError, ~r/exposure_mode must be/, fn ->
        Config.validate!(cfg)
      end
    end

    test "invalid nowcast raises" do
      cfg = Config.new(nowcast: :bogus)

      assert_raise ArgumentError, ~r/nowcast must be/, fn ->
        Config.validate!(cfg)
      end
    end

    test "safety warning for beta_max too small logs but does not raise" do
      import ExUnit.CaptureLog

      cfg = Config.new(beta_true: 1.08, beta_max: 1.06)

      log =
        capture_log(fn ->
          assert Config.validate!(cfg) == cfg
        end)

      assert log =~ "beta_max"
    end

    test "safety warning for renew_lead <= grant_latency" do
      import ExUnit.CaptureLog

      cfg = Config.new(renew_lead: 1.0, grant_latency: 1.0)

      log =
        capture_log(fn ->
          assert Config.validate!(cfg) == cfg
        end)

      assert log =~ "renew_lead"
    end
  end
end

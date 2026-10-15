defmodule BudgetPacingSim.Config do
  @moduledoc """
  All simulator parameters. Time unit: minutes. Money unit: arbitrary.

  Parameters are grouped into
  - the *world* (true demand, true DB behaviour) — unknown to the center,
  - the *center's assumptions* (what it believes about delays and DB/client mismatch),
  - the *policy* (pacing strategy and grant sizing).
  """

  @enforce_keys []
  defstruct [
    # ---------------- budget & horizon ----------------
    b: 1.0e6,                    # total budget, hard cap
    t: 7 * 1440.0,              # period [min] (starts Monday 00:00)
    dt: 1.0,                     # simulation step [min]

    # ---------------- world: client demand ----------------
    n_clients: 50,
    demand_ratio: 1.5,           # mean total demand / (B/T)
    size_spread: 0.8,            # lognormal σ of client sizes
    noise_cv: 0.5,               # Gaussian noise per step, relative to mean rate
    daily_amp: 0.6,              # demand ∝ 1 + daily_amp·sin(..), trough at midnight
    daily_phase_jitter: 60.0,    # per-client daily phase shift, std [min]
    weekly_amp: 0.3,             # weekend (Sat, Sun) demand reduction
    drift_sigma: 0.15,           # slow multiplicative drift of each client (OU on log)
    drift_tau: 360.0,            # drift correlation time [min]
    shock_start: :infinity,      # optional demand shock window [min]
    shock_length: 0.0,
    shock_factor: 1.0,           # demand multiplier inside the shock window

    # ---------------- world: central DB ----------------
    d_delay: 30.0,               # DB delay [min]
    d_jitter: 0.0,               # extra delay, uniform in [0, D_jitter] [min]
    beta_true: 1.02,             # DB amount / client-counted amount
    beta_noise: 0.01,            # relative noise of that ratio per client-step (clipped ±3σ)
    report_lag: 1.0,             # latency of client usage/demand reports [min]

    # ---------------- center's assumptions (safety) ----------------
    d_assumed: nil,              # delay used for estimation (nil → d_delay)
    d_max: nil,                  # delay bound used for the hard-cap invariant (nil → d_delay + d_jitter)
    beta_max: 1.06,              # upper bound of DB/client ratio used for the hard cap
    delta: 0.0,                  # extra safety margin, fraction of B
    exposure_mode: :reported,    # :reported (use client counters) | :full (full grant amounts)
    return_unused: true,         # clients may return unused grant early
    regrant_threshold: 0.3,      # client asks for a bigger grant when its demand rose more than this
    return_keep_factor: 2.0,     # partial return: client keeps ≤ factor × its expected use

    # ---------------- policy: pacing ----------------
    strategy: :adaptive,         # :uniform | :adaptive (learns daily demand profile)
    nowcast: :reports,           # :reports (Y + β̂·reported spend in the blind window) | :none (pace on Y)
    demand_headroom: 0.5,        # grant rate ≤ (1+h)·client demand estimate
    ewma_minutes: 30.0,          # smoothing of per-client demand estimate
    beta_ewma_minutes: 240.0,    # smoothing of β̂ (DB vs client reports)
    profile_bins: 96,            # daily profile resolution (96 → 15 min)
    profile_alpha: 0.5,          # weight of the newest day in the learned profile
    level_minutes: 240.0,        # smoothing of demand level vs profile (0 = no level correction)
    finish_buffer: 60.0,         # pace as if the period ends this much earlier [min]
    forecast_haircut: 0.2,       # plan as if future demand is this fraction lower than forecast

    # ---------------- policy: grants ----------------
    tau_frac: 0.01,              # τ = clamp(tau_frac·(T−t), tau_min, tau_max)
    tau_min: 5.0,
    tau_max: 60.0,
    renew_lead: 3.0,             # request next grant when < lead minutes of grant left
    grant_latency: 1.0,          # request → grant delivery [min]
    burst_minutes: 5.0,          # client token bucket size, in minutes of grant rate
    min_grant: 1.0,              # smaller grants are not issued
    alert_tol: 0.001,            # feasibility alert ignores remaining budget below alert_tol·B

    # ---------------- run ----------------
    seed: 1,
    record_every: 10             # time-series sampling [steps]
  ]

  @type t :: %__MODULE__{}

  @doc "Create a new Config with defaults."
  def new(overrides \\ []) do
    struct!(__MODULE__, overrides)
  end

  @doc "Return a copy of `cfg` with the given fields replaced."
  def with(%__MODULE__{} = cfg, overrides) do
    struct!(cfg, overrides)
  end

  # TOML key → struct field mapping. TOML uses flat groups [world], [center], [policy], [run].
  # Atom keys that differ from TOML string keys are mapped here.
  @toml_key_map %{
    # [world]
    "b" => :b, "t" => :t, "dt" => :dt,
    "n_clients" => :n_clients, "demand_ratio" => :demand_ratio,
    "size_spread" => :size_spread, "noise_cv" => :noise_cv,
    "daily_amp" => :daily_amp, "daily_phase_jitter" => :daily_phase_jitter,
    "weekly_amp" => :weekly_amp, "drift_sigma" => :drift_sigma,
    "drift_tau" => :drift_tau, "shock_start" => :shock_start,
    "shock_length" => :shock_length, "shock_factor" => :shock_factor,
    "d_delay" => :d_delay, "d_jitter" => :d_jitter,
    "beta_true" => :beta_true, "beta_noise" => :beta_noise,
    "report_lag" => :report_lag,
    # [center]
    "d_assumed" => :d_assumed, "d_max" => :d_max,
    "beta_max" => :beta_max, "delta" => :delta,
    "exposure_mode" => :exposure_mode, "return_unused" => :return_unused,
    "regrant_threshold" => :regrant_threshold, "return_keep_factor" => :return_keep_factor,
    # [policy]
    "strategy" => :strategy, "nowcast" => :nowcast,
    "demand_headroom" => :demand_headroom, "ewma_minutes" => :ewma_minutes,
    "beta_ewma_minutes" => :beta_ewma_minutes, "profile_bins" => :profile_bins,
    "profile_alpha" => :profile_alpha, "level_minutes" => :level_minutes,
    "finish_buffer" => :finish_buffer, "forecast_haircut" => :forecast_haircut,
    "tau_frac" => :tau_frac, "tau_min" => :tau_min, "tau_max" => :tau_max,
    "renew_lead" => :renew_lead, "grant_latency" => :grant_latency,
    "burst_minutes" => :burst_minutes, "min_grant" => :min_grant,
    "alert_tol" => :alert_tol,
    # [run]
    "seed" => :seed, "record_every" => :record_every
  }

  # Fields that are atoms in the struct but strings in TOML
  @atom_fields [:strategy, :nowcast, :exposure_mode]

  @doc """
  Load config from a TOML file. Missing keys use defaults.
  Raises on file errors or unknown keys.
  """
  def load!(path) do
    case Toml.decode_file(path) do
      {:ok, toml} ->
        overrides =
          toml
          |> flatten_toml()
          |> Enum.map(fn {k, v} ->
            field = Map.fetch!(@toml_key_map, k)
            {field, coerce(field, v)}
          end)

        new(overrides)

      {:error, reason} ->
        raise ArgumentError, "failed to load config from #{path}: #{inspect(reason)}"
    end
  end

  # Flatten nested TOML tables (e.g. %{"world" => %{"b" => 1e6}}) into flat key-value pairs
  defp flatten_toml(map) do
    Enum.flat_map(map, fn
      {_section, inner} when is_map(inner) ->
        Enum.to_list(inner)

      {key, value} ->
        [{key, value}]
    end)
  end

  # Coerce TOML values to struct types
  defp coerce(field, value) when field in @atom_fields and is_binary(value) do
    String.to_atom(value)
  end

  defp coerce(:shock_start, "infinity"), do: :infinity
  defp coerce(:shock_start, :infinity), do: :infinity
  defp coerce(_field, value), do: value

  require Logger

  @doc """
  Validate config. Raises on invalid values, logs warnings on safety concerns.
  Returns the config unchanged if valid.
  """
  def validate!(%__MODULE__{} = cfg) do
    unless cfg.strategy in [:uniform, :adaptive] do
      raise ArgumentError, "strategy must be :uniform or :adaptive, got #{inspect(cfg.strategy)}"
    end

    unless cfg.exposure_mode in [:reported, :full] do
      raise ArgumentError,
            "exposure_mode must be :reported or :full, got #{inspect(cfg.exposure_mode)}"
    end

    unless cfg.nowcast in [:reports, :none] do
      raise ArgumentError, "nowcast must be :reports or :none, got #{inspect(cfg.nowcast)}"
    end

    unless d_max(cfg) >= cfg.report_lag do
      raise ArgumentError, "d_max must be >= report_lag"
    end

    if cfg.renew_lead <= cfg.grant_latency do
      Logger.warning("renew_lead <= grant_latency: clients will idle between grants")
    end

    if cfg.beta_true * (1 + 3 * cfg.beta_noise) > cfg.beta_max do
      Logger.warning(
        "true DB/client ratio can exceed beta_max: hard cap is not guaranteed"
      )
    end

    if cfg.d_delay + cfg.d_jitter > d_max(cfg) do
      Logger.warning("true delay can exceed d_max: hard cap is not guaranteed")
    end

    cfg
  end

  @doc "D_assumed: defaults to d_delay when nil."
  def d_assumed(%__MODULE__{d_assumed: nil, d_delay: d}), do: d
  def d_assumed(%__MODULE__{d_assumed: val}), do: val

  @doc "D_max: defaults to d_delay + d_jitter when nil."
  def d_max(%__MODULE__{d_max: nil, d_delay: d, d_jitter: j}), do: d + j
  def d_max(%__MODULE__{d_max: val}), do: val
end

defmodule BudgetPacingSim.Model do
  @moduledoc """
  Pure functions: demand patterns, shock, exposure, profile integration.
  These have no side effects and match the Julia implementations in model.jl.
  """

  alias BudgetPacingSim.{Config, Grant}

  @day 1440.0

  @doc """
  Daily x weekly demand shape (not normalized). The center never sees this function.
  Matches model.jl:base_pattern.
  """
  def base_pattern(%Config{} = cfg, t, phase) do
    daily = 1.0 + cfg.daily_amp * :math.sin(2.0 * :math.pi() * (t + phase) / @day - :math.pi() / 2.0)
    day_of_week = floor(t / @day) |> rem(7)
    weekly = if day_of_week >= 5, do: 1.0 - cfg.weekly_amp, else: 1.0
    daily * weekly
  end

  @doc """
  Demand shock multiplier. Returns shock_factor inside [shock_start, shock_start + shock_length),
  1.0 outside. Matches model.jl:shock.
  """
  def shock(%Config{shock_start: :infinity}, _t), do: 1.0

  def shock(%Config{} = cfg, t) do
    if t >= cfg.shock_start and t < cfg.shock_start + cfg.shock_length do
      cfg.shock_factor
    else
      1.0
    end
  end

  @doc """
  Upper bound on DB spend from grant `g` that may not yet be included in the observed DB value Y.
  `ccli_fn` is a function (client_id, index) -> cumulative client-counted spend at that index.
  `s` is the latest index guaranteed to be included in Y (now - D_max).
  `now` is the current tick index.
  Returns 0 when the grant is settled.
  Matches model.jl:exposure.
  """
  def exposure(%Grant{} = g, ccli_fn, s, now, %Config{} = cfg) do
    sw = g.switch_tick || :infinity
    released = g.release_tick != nil and now >= g.release_tick

    cond do
      released and s >= sw ->
        0.0

      cfg.exposure_mode == :full ->
        cfg.beta_max * g.amount

      true ->
        used_safe =
          if s > g.issue_tick do
            safe_idx = min(s, sw)
            ccli_fn.(g.client, safe_idx) - ccli_fn.(g.client, g.issue_tick)
          else
            0.0
          end

        if released do
          # sw is known (integer) since released is true and release requires switch
          used_final = ccli_fn.(g.client, sw) - ccli_fn.(g.client, g.issue_tick)
          cfg.beta_max * (used_final - used_safe)
        else
          cfg.beta_max * (g.amount - used_safe)
        end
    end
  end

  @doc """
  Map time t to a daily profile bin (1-based). Matches model.jl:bin_of.
  """
  def bin_of(%Config{} = cfg, t) do
    bin_len = @day / cfg.profile_bins
    floor(fmod(t, @day) / bin_len) + 1
  end

  @doc """
  Expected total demand over [t, t_end] from the learned daily profile, scaled by level.
  `profile` is a list (1-based bins), `seen` is a list of booleans, `level` is the current
  level factor, `lam_long` is the fallback for unseen bins.
  Matches model.jl:remaining_demand.
  """
  def remaining_demand(%Config{} = cfg, profile, seen, level, lam_long, t, t_end) do
    ctx = %{
      cfg: cfg,
      profile: profile,
      seen: seen,
      level: level,
      lam_long: lam_long,
      t_end: t_end,
      bin_len: @day / cfg.profile_bins
    }

    do_remaining_demand(ctx, t, 0.0)
  end

  defp do_remaining_demand(%{t_end: t_end}, t, acc) when t >= t_end - 1.0e-9, do: acc

  defp do_remaining_demand(ctx, t, acc) do
    b = bin_of(ctx.cfg, t)
    # end of this bin or t_end, whichever is first
    bin_start = floor(t / ctx.bin_len) * ctx.bin_len
    tend = min(bin_start + ctx.bin_len, ctx.t_end)

    rate =
      if Enum.at(ctx.seen, b - 1) do
        ctx.level * Enum.at(ctx.profile, b - 1)
      else
        ctx.lam_long
      end

    do_remaining_demand(ctx, tend, acc + rate * (tend - t))
  end

  # Floating-point modulo (always non-negative)
  defp fmod(a, b) do
    r = a - Float.floor(a / b) * b
    if r < 0, do: r + b, else: r
  end
end

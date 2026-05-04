defmodule KiteAgentHub.CollectiveIntelligence.MethodSeederTest do
  @moduledoc """
  Coverage for the M-007 carry-trade conditional backtester:
    * `m007_conditions_met?/2` — annualised volatility gate
    * `insights_for_m007/2`    — gate-then-delegate to `Seeder`

  These are pure functions that determine whether seed data lands in
  the corpus, so a regression here silently changes the win-rate
  baselines users see in `/api/v1/collective-intelligence`.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.CollectiveIntelligence.MethodSeeder

  defp const_bars(n, price), do: Enum.map(1..n, fn _ -> %{c: price} end)

  defp swinging_bars(n, base, swing) do
    Enum.map(1..n, fn i ->
      offset = if rem(i, 2) == 0, do: swing, else: -swing
      %{c: base + offset}
    end)
  end

  describe "m007_conditions_met?/2" do
    test "false when fewer than min_bars are provided" do
      bars = const_bars(15, 100.0)
      refute MethodSeeder.m007_conditions_met?(bars, min_bars: 20)
    end

    test "true when bars are constant (zero realised vol)" do
      bars = const_bars(40, 100.0)
      assert MethodSeeder.m007_conditions_met?(bars, max_ann_vol: 10.0)
    end

    test "false when bars show high realised vol" do
      bars = swinging_bars(40, 100.0, 5.0)
      refute MethodSeeder.m007_conditions_met?(bars, max_ann_vol: 10.0)
    end

    test "respects custom max_ann_vol threshold" do
      bars = swinging_bars(40, 100.0, 0.05)
      # Tiny swings → low vol; should pass with any reasonable threshold
      assert MethodSeeder.m007_conditions_met?(bars, max_ann_vol: 50.0)
    end

    test "tolerates OANDA mid-close candle shape" do
      bars =
        Enum.map(1..40, fn _ -> %{"mid" => %{"c" => "100.0"}} end)

      assert MethodSeeder.m007_conditions_met?(bars, max_ann_vol: 10.0)
    end

    test "tolerates OANDA bid/ask candle shape" do
      bars = Enum.map(1..40, fn _ -> %{"bid" => %{"c" => "99.5"}} end)
      assert MethodSeeder.m007_conditions_met?(bars, max_ann_vol: 10.0)
    end

    test "tolerates string-keyed flat shape" do
      bars = Enum.map(1..40, fn _ -> %{"c" => 100.0} end)
      assert MethodSeeder.m007_conditions_met?(bars, max_ann_vol: 10.0)
    end
  end

  describe "insights_for_m007/2" do
    test "returns [] when conditions are NOT met (high vol)" do
      bars = swinging_bars(40, 100.0, 5.0)

      result =
        MethodSeeder.insights_for_m007(bars,
          symbol: "AUD_JPY",
          platform: "oanda_practice",
          max_ann_vol: 10.0
        )

      assert result == []
    end

    test "delegates to Seeder when conditions ARE met (low vol)" do
      # 30 bars of slow drift = low realised vol
      bars =
        Enum.map(1..30, fn i ->
          %{
            c: 100.0 + i * 0.001,
            t: DateTime.utc_now() |> DateTime.add(-i * 86_400, :second) |> DateTime.to_iso8601()
          }
        end)

      result =
        MethodSeeder.insights_for_m007(bars,
          symbol: "AUD_JPY",
          platform: "oanda_practice",
          hold_bars: 5,
          max_ann_vol: 50.0
        )

      # Should produce some insights — exact count depends on hold window,
      # but it must be > 0 to prove the delegation path actually fires.
      assert length(result) > 0
      assert Enum.all?(result, &(&1.platform == "oanda_practice"))
      assert Enum.all?(result, &(&1.market_class == "forex"))
      assert Enum.all?(result, &(&1.agent_type == "synthetic"))
    end
  end
end

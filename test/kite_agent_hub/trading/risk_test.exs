defmodule KiteAgentHub.Trading.RiskTest do
  @moduledoc """
  Trading.Risk is the runtime read path. The contract callers depend on:
    * Empty / missing risk_config → defaults with source: :module_default.
    * Valid override → user value with source: :user_defined.
    * Structurally bad row → {:error, :invalid_risk_config} (fail-closed).
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.{KiteAgent, Risk}

  describe "per_trade_notional_cap/1" do
    test "empty config returns module default" do
      assert {:ok, decimal, :module_default} =
               Risk.per_trade_notional_cap(%KiteAgent{risk_config: %{}})

      assert Decimal.equal?(decimal, Decimal.new("5000"))
    end

    test "user override returns user_defined" do
      cfg = %{"per_trade_notional_cap_usd" => "1500"}

      assert {:ok, decimal, :user_defined} =
               Risk.per_trade_notional_cap(%KiteAgent{risk_config: cfg})

      assert Decimal.equal?(decimal, Decimal.new("1500"))
    end

    test "fails closed on a value above the hard ceiling (manually edited row)" do
      cfg = %{"per_trade_notional_cap_usd" => "9999"}

      assert {:error, :invalid_risk_config} =
               Risk.per_trade_notional_cap(%KiteAgent{risk_config: cfg})
    end

    test "fails closed on a non-numeric value" do
      cfg = %{"per_trade_notional_cap_usd" => "lots"}

      assert {:error, :invalid_risk_config} =
               Risk.per_trade_notional_cap(%KiteAgent{risk_config: cfg})
    end
  end

  describe "profit_trim_ladder/1" do
    test "empty config returns defaults" do
      assert {:ok, %{partial_pct: 3, full_pct: 5}, :module_default} =
               Risk.profit_trim_ladder(%KiteAgent{risk_config: %{}})
    end

    test "fails closed when full <= partial" do
      cfg = %{"profit_trim_partial_pct" => 6, "profit_trim_full_pct" => 5}

      assert {:error, :invalid_risk_config} =
               Risk.profit_trim_ladder(%KiteAgent{risk_config: cfg})
    end
  end

  describe "market_hours_only?/1" do
    test "default is true" do
      assert {:ok, true, :module_default} =
               Risk.market_hours_only?(%KiteAgent{risk_config: %{}})
    end

    test "fails closed on non-boolean" do
      assert {:error, :invalid_risk_config} =
               Risk.market_hours_only?(%KiteAgent{risk_config: %{"market_hours_only" => "yes"}})
    end
  end
end

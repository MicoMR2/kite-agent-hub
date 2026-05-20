defmodule KiteAgentHub.Trading.OptionsPreflightTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.OptionsPreflight

  # NVDA Jan 17 2026 $500 call.
  @nvda_call "NVDA260117C00500000"
  @nvda_put "NVDA260117P00450000"

  describe "validate/2 — happy path" do
    test "valid buy with limit price fitting cap" do
      assert {:ok, intent} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy",
                 limit_price: 12.50
               })

      assert intent.symbol == @nvda_call
      assert intent.qty == 1
      assert intent.side == "buy"
      assert intent.limit_price == 12.50
      assert intent.underlying == "NVDA"
      assert intent.option_type == :call
      assert intent.expiration_date == ~D[2026-01-17]
      assert intent.strike == 500.0
      # qty * limit_price * 100 = 1 * 12.50 * 100 = 1_250.0
      assert intent.notional_usd == 1_250.0
    end

    test "valid sell" do
      assert {:ok, _} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_put,
                 qty: 2,
                 side: "sell",
                 limit_price: 5.00
               })
    end

    test "string keys are accepted" do
      assert {:ok, _} =
               OptionsPreflight.validate(%{
                 "symbol" => @nvda_call,
                 "qty" => 1,
                 "side" => "buy",
                 "limit_price" => 1.00
               })
    end
  end

  describe "validate/2 — symbol gating" do
    test "rejects equity ticker" do
      assert {:error, :invalid_symbol, %{symbol: "NVDA"}} =
               OptionsPreflight.validate(%{
                 symbol: "NVDA",
                 qty: 1,
                 side: "buy",
                 limit_price: 10.0
               })
    end

    test "rejects missing symbol" do
      assert {:error, :missing_symbol, _} =
               OptionsPreflight.validate(%{qty: 1, side: "buy", limit_price: 10.0})
    end

    test "rejects empty string symbol" do
      assert {:error, :missing_symbol, _} =
               OptionsPreflight.validate(%{
                 symbol: "",
                 qty: 1,
                 side: "buy",
                 limit_price: 10.0
               })
    end
  end

  describe "validate/2 — side gating (Alpaca contract: buy|sell only)" do
    # Source: https://docs.alpaca.markets/us/docs/options-orders —
    # options orders take side="buy"|"sell"; open/close is implied
    # through side values by Alpaca, not a separate enum.

    test "rejects buy_to_open intent enum (we use 'buy', not the intent verb)" do
      assert {:error, :unsupported_side, %{side: "buy_to_open"}} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy_to_open",
                 limit_price: 10.0
               })
    end

    test "rejects sell_to_close intent enum" do
      assert {:error, :unsupported_side, %{side: "sell_to_close"}} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "sell_to_close",
                 limit_price: 10.0
               })
    end

    test "rejects garbage side" do
      assert {:error, :unsupported_side, %{side: "wat"}} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "wat",
                 limit_price: 10.0
               })
    end
  end

  describe "validate/2 — quantity gating" do
    test "rejects zero contracts" do
      assert {:error, :non_positive_qty, %{qty: 0}} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 0,
                 side: "buy",
                 limit_price: 10.0
               })
    end

    test "rejects negative contracts" do
      assert {:error, :non_positive_qty, %{qty: -1}} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: -1,
                 side: "buy",
                 limit_price: 10.0
               })
    end

    test "rejects fractional qty (Alpaca options reject non-integer)" do
      assert {:error, :non_integer_qty, %{qty: 1.5}} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1.5,
                 side: "buy",
                 limit_price: 10.0
               })
    end

    test "rejects missing qty" do
      assert {:error, :missing_qty, _} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 side: "buy",
                 limit_price: 10.0
               })
    end
  end

  describe "validate/2 — limit price gating" do
    test "rejects missing limit price (cannot size for cap)" do
      assert {:error, :missing_limit_price, _} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy"
               })
    end

    test "rejects zero limit price" do
      assert {:error, :missing_limit_price, _} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy",
                 limit_price: 0
               })
    end
  end

  describe "validate/2 — notional cap" do
    test "rejects when qty * limit_price * 100 exceeds default $5K cap" do
      # 1 contract * $51 * 100 = $5,100 > $5,000 ceiling
      assert {:error, :notional_over_cap, details} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy",
                 limit_price: 51.0
               })

      assert details.notional_usd == 5_100.0
      assert details.cap_usd == 5_000.0
    end

    test "accepts right at the cap boundary" do
      # 1 contract * $50 * 100 = $5,000 — equal-to-cap is allowed
      assert {:ok, _} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy",
                 limit_price: 50.0
               })
    end

    test "honors caller-supplied lower cap" do
      assert {:error, :notional_over_cap, details} =
               OptionsPreflight.validate(
                 %{symbol: @nvda_call, qty: 1, side: "buy", limit_price: 11.0},
                 notional_cap_usd: 1_000
               )

      assert details.notional_usd == 1_100.0
      assert details.cap_usd == 1_000.0
    end
  end

  describe "validate/2 — premium guardrail (IV-bloat auto-reject)" do
    test "rejects when limit_price > 2x supplied max_premium_per_contract" do
      assert {:error, :premium_over_guardrail, details} =
               OptionsPreflight.validate(
                 %{symbol: @nvda_call, qty: 1, side: "buy", limit_price: 25.0},
                 max_premium_per_contract: 10.0
               )

      assert details.limit_price == 25.0
      assert details.max_premium_per_contract == 10.0
      assert details.ceiling == 20.0
    end

    test "accepts at exactly 2x — guardrail is strictly greater-than" do
      assert {:ok, _} =
               OptionsPreflight.validate(
                 %{symbol: @nvda_call, qty: 1, side: "buy", limit_price: 20.0},
                 max_premium_per_contract: 10.0
               )
    end

    test "no guardrail when max_premium_per_contract absent" do
      assert {:ok, _} =
               OptionsPreflight.validate(%{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy",
                 limit_price: 49.99
               })
    end
  end

  describe "validate/2 — underlying allow-list" do
    test "rejects when underlying not in caller-supplied list" do
      assert {:error, :underlying_not_allowed, details} =
               OptionsPreflight.validate(
                 %{
                   symbol: "AAPL260117C00200000",
                   qty: 1,
                   side: "buy",
                   limit_price: 1.0
                 },
                 underlying_allow_list: ["NVDA"]
               )

      assert details.underlying == "AAPL"
      assert details.allow_list == ["NVDA"]
    end

    test "accepts when underlying is in list" do
      assert {:ok, _} =
               OptionsPreflight.validate(
                 %{symbol: @nvda_call, qty: 1, side: "buy", limit_price: 1.0},
                 underlying_allow_list: ["NVDA"]
               )
    end

    test "no allow-list = no restriction" do
      assert {:ok, _} =
               OptionsPreflight.validate(%{
                 symbol: "AAPL260117C00200000",
                 qty: 1,
                 side: "buy",
                 limit_price: 1.0
               })
    end
  end

  describe "contract_multiplier/0" do
    test "is the standard 100-share OCC multiplier" do
      assert OptionsPreflight.contract_multiplier() == 100
    end
  end
end

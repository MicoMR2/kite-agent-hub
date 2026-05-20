defmodule KiteAgentHub.TradingPlatforms.AlpacaClientPlaceOptionsOrderTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  # PR-G.2a — `place_options_order/4` must short-circuit on any
  # preflight rejection before the broker HTTP path. Verified by
  # passing intentionally-bad intents and asserting we get a `{:error,
  # reason, details}` triple without making the network call. Bogus
  # credentials would only matter if the preflight slipped through —
  # which is what we are gating.

  @nvda_call "NVDA260117C00500000"
  @bad_key "no-such-key"
  @bad_secret "no-such-secret"

  test "rejects non-OCC symbol before any broker call" do
    assert {:error, :invalid_symbol, %{symbol: "NVDA"}} =
             AlpacaClient.place_options_order(@bad_key, @bad_secret, %{
               symbol: "NVDA",
               qty: 1,
               side: "buy",
               limit_price: 1.0
             })
  end

  test "rejects non-Alpaca side enum before any broker call" do
    # Alpaca options API takes side="buy"|"sell" only — open/close
    # intent is implied, not a separate enum value.
    assert {:error, :unsupported_side, %{side: "sell_to_open"}} =
             AlpacaClient.place_options_order(@bad_key, @bad_secret, %{
               symbol: @nvda_call,
               qty: 1,
               side: "sell_to_open",
               limit_price: 1.0
             })
  end

  test "rejects over-cap notional (1 * $51 * 100 = $5_100 > $5_000)" do
    assert {:error, :notional_over_cap, details} =
             AlpacaClient.place_options_order(@bad_key, @bad_secret, %{
               symbol: @nvda_call,
               qty: 1,
               side: "buy",
               limit_price: 51.0
             })

    assert details.notional_usd == 5_100.0
    assert details.cap_usd == 5_000.0
  end

  test "rejects fractional contract qty" do
    assert {:error, :non_integer_qty, %{qty: 1.5}} =
             AlpacaClient.place_options_order(@bad_key, @bad_secret, %{
               symbol: @nvda_call,
               qty: 1.5,
               side: "buy",
               limit_price: 1.0
             })
  end

  test "rejects out-of-allow-list underlying (worker-layer NVDA-only gate)" do
    assert {:error, :underlying_not_allowed, details} =
             AlpacaClient.place_options_order(
               @bad_key,
               @bad_secret,
               %{
                 symbol: "AAPL260117C00200000",
                 qty: 1,
                 side: "buy",
                 limit_price: 1.0
               },
               "paper",
               underlying_allow_list: ["NVDA"]
             )

    assert details.underlying == "AAPL"
    assert details.allow_list == ["NVDA"]
  end

  test "rejects premium-guardrail blowout before broker call" do
    assert {:error, :premium_over_guardrail, details} =
             AlpacaClient.place_options_order(
               @bad_key,
               @bad_secret,
               %{
                 symbol: @nvda_call,
                 qty: 1,
                 side: "buy",
                 limit_price: 25.0
               },
               "paper",
               max_premium_per_contract: 5.0
             )

    assert details.limit_price == 25.0
    assert details.ceiling == 10.0
  end
end

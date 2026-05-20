defmodule KiteAgentHub.TradingPlatforms.AlpacaClientOptionsTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  # PR-G.1 — read-only options surface. Pure parser tests; no HTTP /
  # broker mocks. Covers CyberSec ③ (multi-key-fallback defensives) +
  # ⑥ (bounded response shape — no raw payload passthrough).

  describe "option_position?/1" do
    test "true on asset_class us_option" do
      assert AlpacaClient.option_position?(%{"asset_class" => "us_option"})
    end

    test "true on asset_class option (legacy shape)" do
      assert AlpacaClient.option_position?(%{"asset_class" => "option"})
    end

    test "true when contract_type tells us it's a call or put" do
      assert AlpacaClient.option_position?(%{"contract_type" => "call"})
      assert AlpacaClient.option_position?(%{"contract_type" => "put"})
    end

    test "false on equity position" do
      refute AlpacaClient.option_position?(%{"asset_class" => "us_equity", "symbol" => "NVDA"})
    end

    test "false on missing class + symbol-only payload" do
      refute AlpacaClient.option_position?(%{"symbol" => "NVDA"})
      refute AlpacaClient.option_position?(%{})
    end
  end

  describe "parse_option_position/1" do
    test "extracts bounded fields from a fully populated payload" do
      result =
        AlpacaClient.parse_option_position(%{
          "symbol" => "NVDA260117C00500000",
          "asset_class" => "us_option",
          "underlying_symbol" => "NVDA",
          "contract_type" => "call",
          "expiration_date" => "2026-01-17",
          "strike_price" => "500.00",
          "qty" => "2",
          "qty_available" => "2",
          "side" => "long",
          "avg_entry_price" => "12.50",
          "current_price" => "14.25",
          "market_value" => "2850.00",
          "cost_basis" => "2500.00",
          "unrealized_pl" => "350.00",
          "unrealized_plpc" => "0.14",
          # CyberSec ⑥ — extra broker fields must not bleed into the
          # bounded response. Anything not in the explicit list is
          # dropped here.
          "asset_id" => "should-be-dropped"
        })

      assert result.symbol == "NVDA260117C00500000"
      assert result.underlying == "NVDA"
      assert result.option_type == "call"
      assert result.expiration == "2026-01-17"
      assert result.strike == 500.00
      assert result.qty == 2.0
      assert result.qty_available == 2.0
      assert result.side == "long"
      assert result.avg_entry == 12.50
      assert result.current_price == 14.25
      assert result.market_value == 2850.00
      assert result.cost_basis == 2500.00
      assert result.unrealized_pl == 350.00
      assert result.unrealized_plpc == 0.14
      refute Map.has_key?(result, :asset_id)
    end

    test "falls back to OCC-derived fields when the broker omits the explicit ones" do
      # CyberSec ③ — multi-key-fallback defensives. Alpaca occasionally
      # returns the position without `underlying_symbol` / `expiration_date`
      # / `strike_price`; OCC parse fills the gap.
      result =
        AlpacaClient.parse_option_position(%{
          "symbol" => "NVDA260117C00500000",
          "asset_class" => "us_option",
          "qty" => "1"
        })

      assert result.underlying == "NVDA"
      assert result.option_type == "call"
      assert result.expiration == "2026-01-17"
      assert result.strike == 500.00
      assert result.qty == 1.0
    end

    test "tolerates malformed numerics without raising" do
      # CyberSec ③ — missing / malformed numerics default to nil, not raise.
      result =
        AlpacaClient.parse_option_position(%{
          "symbol" => "NVDA260117C00500000",
          "asset_class" => "us_option",
          "qty" => "not-a-number",
          "market_value" => nil,
          "unrealized_pl" => "abc"
        })

      assert result.qty == nil
      assert result.market_value == nil
      assert result.unrealized_pl == nil
    end

    test "non-OCC symbol leaves OCC-derived fields nil but does not raise" do
      result =
        AlpacaClient.parse_option_position(%{
          "symbol" => "weird-not-occ",
          "asset_class" => "us_option",
          "qty" => "1"
        })

      assert result.underlying == nil
      assert result.option_type == nil
      assert result.expiration == nil
      assert result.strike == nil
      assert result.qty == 1.0
    end
  end

  describe "parse_option_order/1" do
    test "extracts bounded fields from a filled options order" do
      result =
        AlpacaClient.parse_option_order(%{
          "id" => "abc-123",
          "symbol" => "NVDA260117P00450000",
          "underlying_symbol" => "NVDA",
          "contract_type" => "put",
          "expiration_date" => "2026-01-17",
          "strike_price" => "450.00",
          "side" => "buy",
          "qty" => "1",
          "filled_qty" => "1",
          "filled_avg_price" => "8.75",
          "status" => "filled",
          "submitted_at" => "2026-05-19T14:32:11Z",
          "client_order_id" => "should-be-dropped"
        })

      assert result.id == "abc-123"
      assert result.symbol == "NVDA260117P00450000"
      assert result.underlying == "NVDA"
      assert result.option_type == "put"
      assert result.expiration == "2026-01-17"
      assert result.strike == 450.00
      assert result.side == "buy"
      assert result.qty == 1.0
      assert result.filled_qty == 1.0
      assert result.filled_avg_price == 8.75
      assert result.status == "filled"
      assert result.submitted_at == "2026-05-19T14:32:11Z"
      refute Map.has_key?(result, :client_order_id)
    end

    test "OCC fallback on missing explicit fields" do
      result =
        AlpacaClient.parse_option_order(%{
          "id" => "abc-123",
          "symbol" => "NVDA260117P00450000",
          "side" => "buy",
          "qty" => "1",
          "status" => "new"
        })

      assert result.underlying == "NVDA"
      assert result.option_type == "put"
      assert result.expiration == "2026-01-17"
      assert result.strike == 450.00
    end

    test "open / pending order with no fill yields nil price + 0 filled_qty" do
      result =
        AlpacaClient.parse_option_order(%{
          "id" => "abc-123",
          "symbol" => "NVDA260117C00500000",
          "side" => "buy",
          "qty" => "1",
          "filled_qty" => "0",
          "filled_avg_price" => nil,
          "status" => "new"
        })

      assert result.filled_qty == 0.0
      assert result.filled_avg_price == nil
      assert result.status == "new"
    end
  end
end

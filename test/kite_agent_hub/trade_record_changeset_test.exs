defmodule KiteAgentHub.TradeRecordChangesetTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Trading.TradeRecord

  @valid_base %{
    market: "BTC-USDC",
    side: "long",
    action: "buy",
    fill_price: Decimal.new("65000.00"),
    status: "open",
    platform: "alpaca",
    kite_agent_id: Ecto.UUID.generate()
  }

  test "fractional crypto contracts now cast through cleanly (was the silent-drop bug)" do
    cs =
      TradeRecord.changeset(%TradeRecord{}, Map.put(@valid_base, :contracts, "0.001"))

    assert cs.valid?
    # Cast the changeset value rather than relying on the changeset to
    # surface it pre-insert.
    assert Decimal.eq?(Ecto.Changeset.get_change(cs, :contracts), Decimal.new("0.001"))
  end

  test "integer contracts still work (most trades are whole-number)" do
    cs = TradeRecord.changeset(%TradeRecord{}, Map.put(@valid_base, :contracts, 5))

    assert cs.valid?
    assert Decimal.eq?(Ecto.Changeset.get_change(cs, :contracts), Decimal.new(5))
  end

  test "zero contracts still rejected (validate_number greater_than: 0)" do
    cs = TradeRecord.changeset(%TradeRecord{}, Map.put(@valid_base, :contracts, 0))

    refute cs.valid?
    assert {_, _} = cs.errors[:contracts]
  end

  test "negative contracts rejected" do
    cs =
      TradeRecord.changeset(%TradeRecord{}, Map.put(@valid_base, :contracts, Decimal.new("-1")))

    refute cs.valid?
  end
end

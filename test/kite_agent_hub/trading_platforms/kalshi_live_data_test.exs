defmodule KiteAgentHub.TradingPlatforms.KalshiLiveDataTest do
  @moduledoc """
  Pure-parser coverage for PR-I₂'s `KalshiClient.parse_live_data/3`.
  Live event payloads ship a wide range of shapes (sports score /
  election count / weather threshold etc.) — the parser must surface
  whatever it can and never crash on a shape it doesn't recognize.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.KalshiClient

  test "parses a score-style live-data payload" do
    raw = %{"ticker" => "KXNFL-26WK1-LAR", "score" => 24}
    parsed = KalshiClient.parse_live_data(raw, "KXNFL-26WK1-LAR")

    assert parsed.ticker == "KXNFL-26WK1-LAR"
    assert parsed.value == 24
    assert parsed.metadata == raw
    assert %DateTime{} = parsed.fetched_at
  end

  test "parses a count-style payload (election vote count)" do
    raw = %{"ticker" => "KXELECTION-26", "count" => 87_654_321}
    parsed = KalshiClient.parse_live_data(raw, nil)

    assert parsed.ticker == "KXELECTION-26"
    assert parsed.value == 87_654_321
  end

  test "parses a value-style payload (numeric threshold)" do
    raw = %{"ticker" => "KXTEMP-26FOO", "value" => "42"}
    parsed = KalshiClient.parse_live_data(raw, "KXTEMP-26FOO")
    assert parsed.value == 42
  end

  test "missing numeric keys -> value is nil, metadata preserved" do
    raw = %{"ticker" => "KXWEIRD-26", "qualitative_field" => "in_progress"}
    parsed = KalshiClient.parse_live_data(raw, "KXWEIRD-26")
    assert parsed.value == nil
    assert parsed.metadata == raw
  end

  test "fetched_at uses the now arg when provided (replay determinism)" do
    fixed = DateTime.from_naive!(~N[2026-01-01 00:00:00.000000], "Etc/UTC")
    parsed = KalshiClient.parse_live_data(%{"score" => 1}, "KX-A", fixed)
    assert parsed.fetched_at == fixed
  end
end

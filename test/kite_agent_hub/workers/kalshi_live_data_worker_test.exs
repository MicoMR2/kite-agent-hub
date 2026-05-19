defmodule KiteAgentHub.Workers.KalshiLiveDataWorkerTest do
  @moduledoc """
  Hermetic coverage for the pure decision logic in PR-I₂'s live-data
  worker. The side-effecting refresh path (Credentials + Kalshi HTTP
  + cache write) is exercised separately; here we just lock the
  ticker-grouping contract so the worker fans out correctly.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.{KiteAgent, TradeRecord}
  alias KiteAgentHub.Workers.KalshiLiveDataWorker

  defp trade(market, org_id) do
    %TradeRecord{
      market: market,
      kite_agent: %KiteAgent{organization_id: org_id}
    }
  end

  test "groups tickers by org and dedupes within an org" do
    trades = [
      trade("KXFEDDECISION-26SEP-CUT25", "org-a"),
      trade("KXFEDDECISION-26SEP-CUT25", "org-a"),
      trade("KXELECTION-26-DEM", "org-a"),
      trade("KXFEDDECISION-26SEP-CUT25", "org-b")
    ]

    grouped = KalshiLiveDataWorker.group_tickers_by_org(trades)

    assert MapSet.new(Map.get(grouped, "org-a")) ==
             MapSet.new(["KXFEDDECISION-26SEP-CUT25", "KXELECTION-26-DEM"])

    assert Map.get(grouped, "org-b") == ["KXFEDDECISION-26SEP-CUT25"]
  end

  test "filters out rows missing org or agent assoc" do
    trades = [
      trade("KXTEST-26FOO", "org-a"),
      %TradeRecord{market: "KXBARE-26", kite_agent: nil},
      %TradeRecord{market: "KXNOORG-26", kite_agent: %KiteAgent{organization_id: nil}}
    ]

    grouped = KalshiLiveDataWorker.group_tickers_by_org(trades)

    assert grouped == %{"org-a" => ["KXTEST-26FOO"]}
  end

  test "empty trade list returns empty map" do
    assert KalshiLiveDataWorker.group_tickers_by_org([]) == %{}
  end
end

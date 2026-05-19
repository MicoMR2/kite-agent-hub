defmodule KiteAgentHubWeb.KalshiMarketUrlTest do
  @moduledoc """
  PR-J.4 helper coverage for the settlement-row deep-link URL
  builder. Returns nil for unrecognized shapes so the template
  skips rendering a broken link.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHubWeb.DashboardLive

  test "builds /markets/{series} from a standard event ticker" do
    assert "https://kalshi.com/markets/KXFEDDECISION" =
             DashboardLive.kalshi_market_url("KXFEDDECISION-26SEP-CUT25")
  end

  test "handles single-segment ticker as the series" do
    assert "https://kalshi.com/markets/KXSAMPLE" =
             DashboardLive.kalshi_market_url("KXSAMPLE-25NOV30")
  end

  test "rejects tickers with non-alphanumeric leading segment" do
    assert nil == DashboardLive.kalshi_market_url("kx-foo-bar")
    assert nil == DashboardLive.kalshi_market_url("../evil")
    assert nil == DashboardLive.kalshi_market_url("javascript:alert(1)")
  end

  test "rejects empty / no-dash / non-string input" do
    assert nil == DashboardLive.kalshi_market_url("")
    assert nil == DashboardLive.kalshi_market_url("NODASH")
    assert nil == DashboardLive.kalshi_market_url(nil)
    assert nil == DashboardLive.kalshi_market_url(123)
  end
end

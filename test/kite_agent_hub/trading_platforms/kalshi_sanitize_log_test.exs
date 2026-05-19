defmodule KiteAgentHub.TradingPlatforms.KalshiSanitizeLogTest do
  @moduledoc """
  Locks the PR-D₄ contract: `KalshiClient.sanitize_for_log/1` must
  return only a short status string and NEVER let an embedded
  Kalshi response body leak into the output. Pre-PR-D₄ the worker
  + LV + reconciler logged `inspect(reason)` which contained the
  raw body Kalshi shipped back in the error tuple — exactly the
  surface CyberSec 10671①② flagged.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.KalshiClient

  describe "sanitize_for_log/1 — status code extraction" do
    test "401 unauthorized" do
      assert "401" =
               KalshiClient.sanitize_for_log(
                 {:error, "kalshi 401: %{\"error\" => \"invalid_credentials\"}"}
               )
    end

    test "404 not found" do
      assert "404" =
               KalshiClient.sanitize_for_log({:error, "kalshi 404: %{\"error\" => \"market_not_found\"}"})
    end

    test "429 rate limit" do
      assert "429" = KalshiClient.sanitize_for_log({:error, "kalshi 429: %{\"error\" => \"rate_limited\"}"})
    end

    test "500 server error" do
      assert "500" = KalshiClient.sanitize_for_log({:error, "kalshi 500: %{\"stack\" => \"...\"}"})
    end

    test "arbitrary 4xx status reflected" do
      assert "418" = KalshiClient.sanitize_for_log({:error, "kalshi 418: teapot"})
    end
  end

  describe "sanitize_for_log/1 — transport + sign reasons" do
    test "transport error" do
      assert "transport" =
               KalshiClient.sanitize_for_log({:error, "kalshi HTTP: :timeout"})
    end

    test "sign failure" do
      assert "sign" =
               KalshiClient.sanitize_for_log({:error, "kalshi sign failed: pem decode bad"})
    end
  end

  describe "sanitize_for_log/1 — defensive" do
    test "atom error reason" do
      assert "validator_unavailable" =
               KalshiClient.sanitize_for_log({:error, :validator_unavailable})
    end

    test "bare error string without status falls back to unknown" do
      assert "unknown" = KalshiClient.sanitize_for_log({:error, "something unexpected"})
    end

    test "nil and non-tuples produce 'unknown' without crashing" do
      assert "unknown" = KalshiClient.sanitize_for_log(nil)
      assert "unknown" = KalshiClient.sanitize_for_log({:weird, :shape})
      assert "unknown" = KalshiClient.sanitize_for_log(123)
    end
  end

  describe "sanitize_for_log/1 — body suppression (the actual security property)" do
    test "raw body content never appears in the output" do
      payloads = [
        {:error, "kalshi 500: %{\"sensitive_field\" => \"leak_me\"}"},
        {:error, "kalshi 400: %{\"order_id\" => \"o-12345\", \"user_email\" => \"x@y.com\"}"},
        {:error, "kalshi 401: %{\"auth_token_echoed\" => \"bearer eyJ...\"}"}
      ]

      for payload <- payloads do
        out = KalshiClient.sanitize_for_log(payload)
        refute String.contains?(out, "leak"), "leak found in #{inspect(out)} from #{inspect(payload)}"
        refute String.contains?(out, "@"), "PII char in #{inspect(out)}"
        refute String.contains?(out, "bearer"), "auth token in #{inspect(out)}"
        refute String.contains?(out, "order_id"), "order detail in #{inspect(out)}"
      end
    end
  end
end

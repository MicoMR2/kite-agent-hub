defmodule KiteAgentHub.TradingPlatforms.KalshiIdempotencyLiveTest do
  @moduledoc """
  Live-paper integration test for the `client_order_id` idempotency
  contract (PR-B). Excluded from default `mix test` runs — opt in with
  `mix test --include live_paper` from a context that has Kalshi
  demo credentials available (KALSHI_PAPER_KEY_ID + KALSHI_PAPER_PEM
  in env, or run via `fly ssh console` against the prod app where
  the Kalshi creds are already in the DB).

  Tests two variants Phorari called out (msg 10667):

  1. **Same `client_order_id`, same payload** — does Kalshi return the
     original order (true idempotency) or create a duplicate (KAH must
     dedup pre-POST)?
  2. **Same `client_order_id`, different payload** — does Kalshi reject
     as a conflict, or silently accept the second? If accepted, our
     retry-after-timeout could fire a corrupted order on payload drift
     between attempts — that's the real safety question.

  This test documents the live behavior. If #1 shows duplicates,
  KAH-side trade-row dedup is mandatory (not optional fallback). If
  #2 shows silent acceptance, the worker must not let payload drift
  on retry — pin the full payload to the trade row at insert.
  """

  use ExUnit.Case, async: false

  @moduletag :live_paper

  alias KiteAgentHub.TradingPlatforms.KalshiClient

  setup do
    key_id = System.get_env("KALSHI_PAPER_KEY_ID")
    pem = System.get_env("KALSHI_PAPER_PEM")

    if is_nil(key_id) or is_nil(pem) do
      {:skip, "KALSHI_PAPER_KEY_ID / KALSHI_PAPER_PEM not set"}
    else
      # Pick a deterministic test ticker. The reconciler picks up any
      # open orders this test creates on its next sweep; we also do
      # best-effort cleanup at the end via cancel_order.
      ticker = System.get_env("KALSHI_TEST_TICKER") || "BTCZ-26DEC2031-B80000"
      {:ok, %{key_id: key_id, pem: pem, ticker: ticker}}
    end
  end

  describe "client_order_id dedup behavior" do
    @tag :live_paper
    test "same client_order_id, same payload — Kalshi returns original (or rejects duplicate)",
         %{key_id: key_id, pem: pem, ticker: ticker} do
      client_order_id = Ecto.UUID.generate()

      opts = %{
        "client_order_id" => client_order_id,
        "time_in_force" => "good_til_cancelled",
        "order_type" => "limit"
      }

      {:ok, order_1} = KalshiClient.place_order(key_id, pem, ticker, "yes", 1, 1, "paper", opts)

      result_2 = KalshiClient.place_order(key_id, pem, ticker, "yes", 1, 1, "paper", opts)

      case result_2 do
        {:ok, order_2} ->
          # If Kalshi accepted the second post, it MUST be the same order
          # ID for idempotency to be safe. Different IDs = duplicates and
          # KAH-side dedup is mandatory.
          assert order_1.id == order_2.id,
                 "DUPLICATE DETECTED: Kalshi created a second order with the same client_order_id. " <>
                   "KAH-side pre-POST dedup is mandatory, not optional."

        {:error, reason} ->
          # Kalshi rejected the duplicate — that's the strong-idempotency
          # behavior and the safest outcome.
          assert reason =~ "conflict" or reason =~ "duplicate" or reason =~ "client_order_id",
                 "Unexpected error from duplicate POST: #{inspect(reason)}"
      end

      # Best-effort cleanup so the test doesn't leave a resting order.
      _ = KalshiClient.cancel_order(key_id, pem, order_1.id, "paper")
    end

    @tag :live_paper
    test "same client_order_id, DIFFERENT payload — must not silently accept",
         %{key_id: key_id, pem: pem, ticker: ticker} do
      client_order_id = Ecto.UUID.generate()

      opts_a = %{
        "client_order_id" => client_order_id,
        "time_in_force" => "good_til_cancelled",
        "order_type" => "limit"
      }

      {:ok, order_1} = KalshiClient.place_order(key_id, pem, ticker, "yes", 1, 1, "paper", opts_a)

      # Different size + price on the same client_order_id. If Kalshi
      # silently accepts, the second POST changed the order — that's a
      # retry-on-timeout corruption risk we have to guard against KAH-side.
      result_2 = KalshiClient.place_order(key_id, pem, ticker, "yes", 5, 50, "paper", opts_a)

      case result_2 do
        {:ok, order_2} ->
          # The contract: with the same client_order_id, the second
          # response must reference the SAME upstream order (not a new
          # one with the new payload). If it's the same ID, the original
          # 1/1 order is still in book and the new payload was ignored —
          # that's safe. If IDs differ, Kalshi made a second order with
          # the corrupted payload — DANGEROUS.
          assert order_1.id == order_2.id,
                 "PAYLOAD DRIFT ACCEPTED: Kalshi created a second order with mutated payload. " <>
                   "Worker must pin payload to trade row at insert and never recompute on retry."

        {:error, reason} ->
          # Kalshi rejected the conflicting payload — strong-idempotency
          # behavior, safest outcome.
          assert reason =~ "conflict" or reason =~ "mismatch" or reason =~ "client_order_id",
                 "Unexpected error from conflicting-payload POST: #{inspect(reason)}"
      end

      _ = KalshiClient.cancel_order(key_id, pem, order_1.id, "paper")
    end
  end
end

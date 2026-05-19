defmodule KiteAgentHub.CollectiveIntelligenceK3aTest do
  @moduledoc """
  Locks the PR-K3a Kalshi-v2 contract on the pure pieces:

  * Consent version bumped to kci-v2-2026-05-19
  * Prior version (kci-v1-2026-04-25) still exposed for back-compat
  * Schema validates v2 fields against their bucket lists only when set;
    nil leaves the row untouched (v1 rows stay untouched)
  * `kalshi_market_anonymity_safe?/1` returns false for non-binary
    input + unknown markets

  The DB-touching paths (record_trade_outcome / org_consent_version /
  the actual anonymity count query) are exercised via DataCase
  integration tests separately; this file stays async + pure.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.CollectiveIntelligence
  alias KiteAgentHub.CollectiveIntelligence.TradeInsight

  test "consent_version is bumped to v2" do
    assert "kci-v2-2026-05-19" = CollectiveIntelligence.consent_version()
  end

  test "prior_consent_version still exposed for back-compat lookups" do
    assert "kci-v1-2026-04-25" = CollectiveIntelligence.prior_consent_version()
  end

  describe "TradeInsight.changeset/2 — v2 fields nullable" do
    test "v1 row (no v2 fields) is valid" do
      attrs = base_attrs()
      assert %{valid?: true} = TradeInsight.changeset(%TradeInsight{}, attrs)
    end

    test "v2 row with valid bucket values is valid" do
      attrs =
        Map.merge(base_attrs(), %{
          lifecycle_stage_at_exit: "settled",
          implied_prob_at_entry_bucket: "70-80",
          consent_version: "kci-v2-2026-05-19"
        })

      assert %{valid?: true} = TradeInsight.changeset(%TradeInsight{}, attrs)
    end

    test "v2 row with bogus lifecycle stage is rejected" do
      attrs = Map.put(base_attrs(), :lifecycle_stage_at_exit, "weird_new_value")
      changeset = TradeInsight.changeset(%TradeInsight{}, attrs)
      refute changeset.valid?
      assert {:lifecycle_stage_at_exit, _} = List.first(changeset.errors)
    end

    test "v2 row with bogus prob bucket is rejected" do
      attrs = Map.put(base_attrs(), :implied_prob_at_entry_bucket, "200%")
      changeset = TradeInsight.changeset(%TradeInsight{}, attrs)
      refute changeset.valid?
    end

    test "v2 row with old consent version is rejected" do
      attrs = Map.put(base_attrs(), :consent_version, "kci-v0-archaic")
      changeset = TradeInsight.changeset(%TradeInsight{}, attrs)
      refute changeset.valid?
    end
  end

  describe "kalshi_market_anonymity_safe?/1 — defensive" do
    test "non-binary input returns false" do
      refute CollectiveIntelligence.kalshi_market_anonymity_safe?(nil)
      refute CollectiveIntelligence.kalshi_market_anonymity_safe?(123)
      refute CollectiveIntelligence.kalshi_market_anonymity_safe?(%{ticker: "X"})
    end
  end

  defp base_attrs do
    %{
      source_trade_hash: "trade-abc",
      source_org_hash: "org-xyz",
      agent_type: "trading",
      platform: "kalshi",
      market_class: "prediction",
      side: "yes",
      action: "buy",
      status: "settled",
      outcome_bucket: "profit",
      observed_week: ~D[2026-05-18]
    }
  end
end

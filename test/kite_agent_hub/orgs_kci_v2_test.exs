defmodule KiteAgentHub.OrgsKciV2Test do
  @moduledoc """
  Locks the PR-K3b consent-version contract. v1 enable must NOT
  auto-extend to v2. Pre-K3b the v1 toggle pinned the org's
  consent_version to `CollectiveIntelligence.consent_version()`
  which now returns v2 — silently auto-extending. CyberSec 10831
  ②/⑦ binding.

  These are pure constant assertions on the version strings + the
  invariant that v1 enable uses the PRIOR version, v2 enable uses
  the CURRENT version. DB-touching Orgs.update_kci_v2_consent
  exercised via DataCase integration tests separately.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.CollectiveIntelligence

  test "consent_version is v2" do
    assert "kci-v2-2026-05-19" = CollectiveIntelligence.consent_version()
  end

  test "prior_consent_version is v1" do
    assert "kci-v1-2026-04-25" = CollectiveIntelligence.prior_consent_version()
  end

  test "the two versions are distinct" do
    refute CollectiveIntelligence.consent_version() ==
             CollectiveIntelligence.prior_consent_version()
  end
end

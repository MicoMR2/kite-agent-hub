defmodule KiteAgentHub.AuditTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Audit
  alias KiteAgentHub.Audit.AuditLog
  alias KiteAgentHub.Repo

  @user_id 99
  @org_id Ecto.UUID.generate()

  test "log_live_credential_event writes a row for valid input" do
    assert :ok =
             Audit.log_live_credential_event(
               @user_id,
               @org_id,
               :credential_created,
               "alpaca_live"
             )

    [row] = Repo.all(AuditLog)
    assert row.actor_user_id == "99"
    assert row.org_id == @org_id
    assert row.action == "credential_created"
    assert row.target_type == "api_credential"
    assert row.target_id == "alpaca_live"
  end

  test "soft-failure: changeset reject still returns :ok, no row inserted" do
    # Unknown action triggers changeset validation error. The context
    # must log + telemetry + return :ok, not raise.
    assert :ok =
             Audit.log_live_credential_event(
               @user_id,
               @org_id,
               :smuggle_keys,
               "alpaca_live"
             )

    assert Repo.aggregate(AuditLog, :count) == 0
  end

  test "metadata is sanitized before insert" do
    Audit.log_live_credential_event(
      @user_id,
      @org_id,
      :credential_updated,
      "alpaca_live",
      %{"api_key" => "redact_me", "kept" => 1}
    )

    [row] = Repo.all(AuditLog)
    assert row.metadata == %{"kept" => 1}
  end
end

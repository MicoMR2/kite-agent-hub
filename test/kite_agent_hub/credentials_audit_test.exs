defmodule KiteAgentHub.CredentialsAuditTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Audit.AuditLog
  alias KiteAgentHub.Credentials
  alias KiteAgentHub.Repo

  @user_id 7

  setup do
    {:ok, org} =
      Repo.insert(
        KiteAgentHub.Orgs.Organization.changeset(
          %KiteAgentHub.Orgs.Organization{},
          %{name: "test", slug: "test-#{System.unique_integer([:positive])}"}
        )
      )

    %{org: org}
  end

  test "upserting a live-slot credential writes an audit row", %{org: org} do
    {:ok, _} =
      Credentials.upsert_credential(
        org.id,
        "alpaca_live",
        %{"key_id" => "live_key_id", "secret" => "live_secret_value"},
        @user_id
      )

    assert [row] = Repo.all(AuditLog)
    assert row.action == "credential_created"
    assert row.target_id == "alpaca_live"
    assert row.actor_user_id == "7"
    assert row.org_id == org.id
  end

  test "upserting a paper-slot credential does NOT write an audit row", %{org: org} do
    {:ok, _} =
      Credentials.upsert_credential(
        org.id,
        "alpaca",
        %{"key_id" => "paper_key_id", "secret" => "paper_secret_value"},
        @user_id
      )

    assert Repo.aggregate(AuditLog, :count) == 0
  end

  test "deleting a live-slot credential writes an audit row", %{org: org} do
    {:ok, _} =
      Credentials.upsert_credential(
        org.id,
        "alpaca_live",
        %{"key_id" => "live_key_id", "secret" => "live_secret_value"},
        nil
      )

    Credentials.delete_credential(org.id, "alpaca_live", @user_id)

    rows = Repo.all(AuditLog)
    assert Enum.any?(rows, &(&1.action == "credential_deleted"))
  end

  test "no actor_user_id → no audit row even for live slots", %{org: org} do
    {:ok, _} =
      Credentials.upsert_credential(
        org.id,
        "alpaca_live",
        %{"key_id" => "live_key_id", "secret" => "live_secret_value"},
        nil
      )

    assert Repo.aggregate(AuditLog, :count) == 0
  end
end

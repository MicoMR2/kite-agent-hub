defmodule KiteAgentHub.Audit.AuditLogTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Audit.AuditLog
  alias KiteAgentHub.Repo

  @valid_attrs %{
    actor_user_id: "42",
    org_id: Ecto.UUID.generate(),
    action: "credential_created",
    target_type: "api_credential",
    target_id: "alpaca_live",
    metadata: %{}
  }

  describe "insert_changeset/1" do
    test "inserts a row with minimal valid attrs" do
      assert {:ok, row} = @valid_attrs |> AuditLog.insert_changeset() |> Repo.insert()
      assert row.action == "credential_created"
      assert row.target_type == "api_credential"
      assert row.metadata == %{}
      assert %DateTime{} = row.inserted_at
    end

    test "rejects unknown action" do
      cs =
        @valid_attrs
        |> Map.put(:action, "smuggle_keys")
        |> AuditLog.insert_changeset()

      refute cs.valid?
      assert cs.errors[:action]
    end

    test "rejects unknown target_type" do
      cs =
        @valid_attrs
        |> Map.put(:target_type, "user")
        |> AuditLog.insert_changeset()

      refute cs.valid?
      assert cs.errors[:target_type]
    end
  end

  describe "metadata sanitization" do
    test "strips top-level credential-shaped keys" do
      meta = %{
        "normal" => "ok",
        "api_token" => "redacted_please",
        "JWT" => "also_redacted",
        "secret" => "no",
        "password" => "definitely_no"
      }

      cs = @valid_attrs |> Map.put(:metadata, meta) |> AuditLog.insert_changeset()
      cleaned = Ecto.Changeset.get_field(cs, :metadata)
      assert Map.keys(cleaned) == ["normal"]
    end

    test "strips PII default-deny keys" do
      meta = %{
        "ip_address" => "1.2.3.4",
        "user_agent" => "Mozilla...",
        "session_id" => "abc",
        "kept" => "value"
      }

      cs = @valid_attrs |> Map.put(:metadata, meta) |> AuditLog.insert_changeset()
      cleaned = Ecto.Changeset.get_field(cs, :metadata)
      assert Map.keys(cleaned) == ["kept"]
    end

    test "recursively walks nested maps and lists" do
      meta = %{
        "outer" => %{
          "inner" => %{
            "api_key" => "redact",
            "fine" => 1
          },
          "list" => [
            %{"jwt" => "redact", "ok" => true},
            "stringvalue"
          ]
        }
      }

      cs = @valid_attrs |> Map.put(:metadata, meta) |> AuditLog.insert_changeset()
      cleaned = Ecto.Changeset.get_field(cs, :metadata)

      assert cleaned["outer"]["inner"] == %{"fine" => 1}
      [first, second] = cleaned["outer"]["list"]
      assert first == %{"ok" => true}
      assert second == "stringvalue"
    end

    test "rejects metadata over the 4096-byte cap" do
      huge = String.duplicate("a", 5_000)
      cs = @valid_attrs |> Map.put(:metadata, %{"blob" => huge}) |> AuditLog.insert_changeset()

      refute cs.valid?
      assert cs.errors[:metadata]
    end
  end
end

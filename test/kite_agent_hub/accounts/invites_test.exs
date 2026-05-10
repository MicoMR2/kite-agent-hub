defmodule KiteAgentHub.Accounts.InvitesTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Accounts.Invites

  describe "request_access/1" do
    test "creates a pending request with normalized email" do
      assert {:ok, req} =
               Invites.request_access(%{
                 "name" => "Jane",
                 "email" => "  Jane@Example.COM ",
                 "notes" => "I want to trade"
               })

      assert req.status == "pending"
      assert req.email == "jane@example.com"
    end

    test "rejects invalid email" do
      assert {:error, cs} = Invites.request_access(%{"name" => "x", "email" => "not-an-email"})
      refute cs.valid?
    end
  end

  describe "generate_code/2 and consume/3" do
    setup do
      {:ok, admin} =
        KiteAgentHub.Repo.insert(
          KiteAgentHub.Accounts.User.email_changeset(
            %KiteAgentHub.Accounts.User{},
            %{"email" => "admin@example.com"}
          )
        )

      {:ok, req} =
        Invites.request_access(%{"name" => "Bob", "email" => "bob@example.com"})

      %{admin: admin, req: req}
    end

    test "mints a code, peek validates, consume marks used", %{admin: admin, req: req} do
      assert {:ok, _invite, plaintext} = Invites.generate_code(req, admin)
      assert is_binary(plaintext) and byte_size(plaintext) > 16

      assert {:ok, _} = Invites.peek(plaintext)
      assert {:ok, _} = Invites.consume(plaintext, "bob@example.com", admin.id)

      # Second consume must fail (single-use).
      assert {:error, :invalid_or_used} =
               Invites.consume(plaintext, "bob@example.com", admin.id)
    end

    test "consume rejects mismatched email", %{admin: admin, req: req} do
      assert {:ok, _, plaintext} = Invites.generate_code(req, admin)

      assert {:error, :invalid_or_used} =
               Invites.consume(plaintext, "someone-else@example.com", admin.id)
    end

    test "consume rejects expired code", %{admin: admin, req: req} do
      assert {:ok, invite, plaintext} = Invites.generate_code(req, admin)

      KiteAgentHub.Repo.update_all(
        from(c in KiteAgentHub.Accounts.InviteCode, where: c.id == ^invite.id),
        set: [expires_at: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)]
      )

      assert {:error, :expired} = Invites.peek(plaintext)
      assert {:error, :invalid_or_used} = Invites.consume(plaintext, "bob@example.com", admin.id)
    end

    test "approves the access request when code is generated", %{admin: admin, req: req} do
      assert {:ok, _, _} = Invites.generate_code(req, admin)
      assert KiteAgentHub.Repo.get!(KiteAgentHub.Accounts.AccessRequest, req.id).status ==
               "approved"
    end
  end

  describe "admin?/1" do
    test "matches case-insensitive against config" do
      assert Invites.admin?(%{email: "Admin@Example.com"})
      refute Invites.admin?(%{email: "stranger@example.com"})
      refute Invites.admin?(%{})
    end
  end

  import Ecto.Query
end

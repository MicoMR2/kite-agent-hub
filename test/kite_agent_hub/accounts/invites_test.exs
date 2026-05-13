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
        set: [
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
        ]
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

  describe "register_user_with_org/2 invite gate" do
    setup do
      {:ok, admin} =
        KiteAgentHub.Repo.insert(
          KiteAgentHub.Accounts.User.email_changeset(
            %KiteAgentHub.Accounts.User{},
            %{"email" => "admin2@example.com"}
          )
        )

      {:ok, req} =
        Invites.request_access(%{"name" => "Carl", "email" => "carl@example.com"})

      {:ok, _, plaintext} = Invites.generate_code(req, admin)
      %{plaintext: plaintext, req: req}
    end

    test "consumes the code atomically inside the registration transaction", %{plaintext: code} do
      attrs = %{
        "email" => "carl@example.com",
        "password" => "supersecretvalue1234",
        "password_confirmation" => "supersecretvalue1234",
        "accept_terms" => "true"
      }

      assert {:ok, user} =
               KiteAgentHub.Accounts.register_user_with_org(attrs, invite_code: code)

      assert user.email == "carl@example.com"

      # Code is now used — second registration with the same code must fail.
      attrs2 = %{attrs | "email" => "carl2@example.com"}

      assert {:error, {:invite, :invalid_or_used}} =
               KiteAgentHub.Accounts.register_user_with_org(attrs2, invite_code: code)
    end

    test "rejects registration with no code when invite-only is on" do
      Application.put_env(:kite_agent_hub, :invite_only_signup, true)
      on_exit(fn -> Application.put_env(:kite_agent_hub, :invite_only_signup, false) end)

      attrs = %{
        "email" => "nocode@example.com",
        "password" => "supersecretvalue1234",
        "password_confirmation" => "supersecretvalue1234",
        "accept_terms" => "true"
      }

      assert {:error, {:invite, :code_required}} =
               KiteAgentHub.Accounts.register_user_with_org(attrs)
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

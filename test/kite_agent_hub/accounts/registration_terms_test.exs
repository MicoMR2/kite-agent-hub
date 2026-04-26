defmodule KiteAgentHub.Accounts.RegistrationTermsTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Accounts.User

  describe "registration_changeset/3 — terms acceptance" do
    @valid_attrs %{
      "email" => "valid@example.com",
      "password" => "supersecretpassword123",
      "password_confirmation" => "supersecretpassword123"
    }

    test "rejects registration without accept_terms=true" do
      changeset = User.registration_changeset(%User{}, @valid_attrs)
      refute changeset.valid?
      assert {"you must accept the Terms of Service and Privacy Policy", _} =
               changeset.errors[:accept_terms]
    end

    test "rejects registration with accept_terms=false" do
      attrs = Map.put(@valid_attrs, "accept_terms", "false")
      changeset = User.registration_changeset(%User{}, attrs)
      refute changeset.valid?
      assert changeset.errors[:accept_terms]
    end

    test "accepts registration with accept_terms=true and stamps accepted_terms_at" do
      attrs = Map.put(@valid_attrs, "accept_terms", "true")
      changeset = User.registration_changeset(%User{}, attrs)
      assert changeset.valid?
      assert %DateTime{} = Ecto.Changeset.get_change(changeset, :accepted_terms_at)
    end

    test "require_terms_acceptance: false skips the check (live form-render path)" do
      changeset =
        User.registration_changeset(%User{}, @valid_attrs,
          validate_unique: false,
          hash_password: false,
          require_terms_acceptance: false
        )

      refute changeset.errors[:accept_terms]
    end
  end
end

defmodule KiteAgentHub.Accounts.Invites do
  @moduledoc """
  Invite-only signup gate.

  Two surfaces:
    * `request_access/1` — public, anyone can submit.
    * `generate_code/2`  — admin-only, mints a one-time code for a request.
    * `validate_and_consume/2` — called inside the registration transaction.

  Codes are stored as SHA-256 hashes (never plaintext). Consume is atomic
  via `UPDATE … WHERE used_at IS NULL RETURNING` to prevent double-use under
  concurrent requests.
  """

  import Ecto.Query, warn: false
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Accounts.{AccessRequest, InviteCode, UserNotifier}

  @code_bytes 16
  @default_ttl_days 14

  ## Access requests

  def request_access(attrs) do
    case AccessRequest.request_changeset(attrs) |> Repo.insert() do
      {:ok, req} ->
        Task.Supervisor.start_child(KiteAgentHub.TaskSupervisor, fn ->
          UserNotifier.deliver_access_request_notification(req)
        end)

        {:ok, req}

      {:error, _} = err ->
        err
    end
  end

  def list_access_requests(opts \\ []) do
    status = Keyword.get(opts, :status, "pending")

    AccessRequest
    |> where([r], r.status == ^status)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  def get_access_request!(id), do: Repo.get!(AccessRequest, id)

  ## Code generation

  @doc """
  Mint a fresh invite code for an access request. Returns `{:ok, %InviteCode{},
  plaintext}` — the plaintext is shown to the admin once and never persisted.
  """
  def generate_code(%AccessRequest{} = req, %{id: admin_id}, opts \\ []) do
    ttl_days = Keyword.get(opts, :ttl_days, @default_ttl_days)
    plaintext = generate_plaintext()
    hash = hash(plaintext)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl_days, :day)
      |> DateTime.truncate(:second)

    attrs = %{
      code_hash: hash,
      email: req.email,
      expires_at: expires_at,
      created_by_id: admin_id,
      access_request_id: req.id
    }

    Repo.transaction(fn ->
      {:ok, code} = InviteCode.insert_changeset(attrs) |> Repo.insert()

      {:ok, _} =
        AccessRequest.status_changeset(req, "approved", admin_id)
        |> Repo.update()

      {code, plaintext}
    end)
    |> case do
      {:ok, {code, plain}} -> {:ok, code, plain}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Validation / consumption

  @doc """
  Look up a code and verify it without consuming it. Used by the form preview
  before the user fills in the rest of the registration page.
  """
  def peek(plaintext) when is_binary(plaintext) do
    hash = hash(plaintext)
    now = DateTime.utc_now()

    InviteCode
    |> where([c], c.code_hash == ^hash)
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid}
      %InviteCode{used_at: %DateTime{}} -> {:error, :used}
      %InviteCode{expires_at: exp} = c ->
        if DateTime.compare(exp, now) == :lt, do: {:error, :expired}, else: {:ok, c}
    end
  end

  def peek(_), do: {:error, :invalid}

  @doc """
  Atomically consume a code. Returns `{:ok, %InviteCode{}}` if and only if the
  code existed, was unexpired, unused, and (if email-locked) matches the
  signup email. Pass `signup_email` lowercased.
  """
  def consume(plaintext, signup_email, user_id) when is_binary(plaintext) do
    hash = hash(plaintext)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    email = String.downcase(signup_email)

    query =
      from c in InviteCode,
        where: c.code_hash == ^hash,
        where: is_nil(c.used_at),
        where: c.expires_at > ^now,
        where: is_nil(c.email) or c.email == ^email

    case Repo.update_all(query, set: [used_at: now, used_by_user_id: user_id]) do
      {1, _} -> {:ok, Repo.get_by!(InviteCode, code_hash: hash)}
      {0, _} -> {:error, :invalid_or_used}
    end
  end

  def consume(_, _, _), do: {:error, :invalid_or_used}

  ## Feature flag

  def enabled? do
    Application.get_env(:kite_agent_hub, :invite_only_signup, false)
  end

  ## Admin gate

  def admin?(%{email: email}) when is_binary(email) do
    String.downcase(email) in admin_emails()
  end

  def admin?(_), do: false

  defp admin_emails do
    (System.get_env("ADMIN_EMAILS") ||
       Application.get_env(:kite_agent_hub, :admin_emails, ""))
    |> String.split(",", trim: true)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  ## Internals

  defp generate_plaintext do
    :crypto.strong_rand_bytes(@code_bytes)
    |> Base.encode32(case: :lower, padding: false)
  end

  defp hash(plaintext), do: :crypto.hash(:sha256, plaintext)
end

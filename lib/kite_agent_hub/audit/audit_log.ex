defmodule KiteAgentHub.Audit.AuditLog do
  @moduledoc """
  Append-only audit row for sensitive operations.

  Per CyberSec ask (a) at msg 9199, `actor_user_id` and `org_id` are
  plain UUID-as-text strings — NOT belongs_to foreign keys. The
  audit trail must survive long after the originating user or org
  row is deleted, so we keep the original UUID forever even if the
  referential target is gone.

  `metadata` is sanitized recursively before insert: credential-
  shaped keys (regex from PR-3) and the PII allowlist
  (ip_address, user_agent, session_id) are stripped at every level
  of the structure. The serialized JSON is hard-capped at 4_096
  bytes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_actions ~w(
    credential_created
    credential_updated
    credential_deleted
    agent_chain_changed
  )
  @valid_targets ~w(api_credential kite_agent)

  @max_metadata_bytes 4_096

  # Recursive credential-shape rejection. Matches the regex used by
  # `Trading.TriggerEvent.validate_payload_no_credentials/1` so the
  # two append-only audit/outbox paths stay in lockstep.
  @forbidden_key_re ~r/(?:^|[_-])?(?:token|jwt|secret|api[_-]?key|password)(?:[_-]|$)/i

  # PII default-deny list (CyberSec ask b, msg 9199). These keys are
  # stripped from audit metadata unless an explicit follow-up PR
  # whitelists them.
  @forbidden_pii_keys ~w(ip_address user_agent session_id)

  def valid_actions, do: @valid_actions
  def valid_targets, do: @valid_targets

  schema "audit_logs" do
    field :actor_user_id, :string
    field :org_id, :string
    field :action, :string
    field :target_type, :string
    field :target_id, :string
    field :metadata, :map, default: %{}

    field :inserted_at, :utc_datetime
  end

  def insert_changeset(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    %__MODULE__{}
    |> cast(attrs, [
      :actor_user_id,
      :org_id,
      :action,
      :target_type,
      :target_id,
      :metadata
    ])
    |> validate_required([:actor_user_id, :org_id, :action, :target_type, :target_id])
    |> validate_inclusion(:action, @valid_actions)
    |> validate_inclusion(:target_type, @valid_targets)
    |> sanitize_metadata()
    |> validate_metadata_size()
    |> put_inserted_at()
  end

  defp sanitize_metadata(changeset) do
    case get_change(changeset, :metadata) || get_field(changeset, :metadata) do
      nil ->
        put_change(changeset, :metadata, %{})

      m when is_map(m) ->
        put_change(changeset, :metadata, do_sanitize(m))

      _ ->
        put_change(changeset, :metadata, %{})
    end
  end

  defp do_sanitize(value) when is_map(value) do
    value
    |> Enum.reject(fn {k, _} ->
      key_str = to_string(k)
      Regex.match?(@forbidden_key_re, key_str) or key_str in @forbidden_pii_keys
    end)
    |> Map.new(fn {k, v} -> {k, do_sanitize(v)} end)
  end

  defp do_sanitize(value) when is_list(value), do: Enum.map(value, &do_sanitize/1)
  defp do_sanitize(value), do: value

  defp validate_metadata_size(changeset) do
    case get_field(changeset, :metadata) do
      m when is_map(m) ->
        case Jason.encode(m) do
          {:ok, json} when byte_size(json) <= @max_metadata_bytes ->
            changeset

          {:ok, _} ->
            add_error(changeset, :metadata, "exceeds #{@max_metadata_bytes} byte cap")

          {:error, _} ->
            add_error(changeset, :metadata, "is not JSON-encodable")
        end

      _ ->
        changeset
    end
  end

  defp put_inserted_at(changeset) do
    if get_field(changeset, :inserted_at) do
      changeset
    else
      put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end

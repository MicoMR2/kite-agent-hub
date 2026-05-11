defmodule KiteAgentHub.Trading.TriggerEvent do
  @moduledoc """
  Outbox row for Passport-routed agent intents.

  When a trading agent's `payment_rail == "per_trade"`, AgentRunner
  inserts a `TriggerEvent` instead of enqueuing a broker job — the
  user's kpass-side runner polls `GET /api/triggers/pending` (PR-6),
  executes the trade locally with the brokerage credentials it holds,
  and pays the per-trade fee via x402 (PR-4).

  Payload is plain JSON metadata only — the trade-intent shape used
  for direct broker dispatch (market, side, action, contracts,
  fill_price, etc.). Credentials NEVER live in this row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending delivered expired)
  @max_payload_bytes 16_384
  # Keys whose presence in a payload is treated as an
  # accidentally-leaked credential. CyberSec ask #4 (msg 9061).
  @forbidden_key_re ~r/(?:^|[_-])?(?:token|jwt|secret|api[_-]?key|password)(?:[_-]|$)/i

  schema "trigger_events" do
    belongs_to :agent, KiteAgentHub.Trading.KiteAgent

    field :event_type, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :idempotency_key, :string
    field :delivered_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :agent_id,
      :event_type,
      :payload,
      :status,
      :idempotency_key,
      :delivered_at,
      :expires_at
    ])
    |> validate_required([:agent_id, :event_type, :payload, :idempotency_key])
    |> validate_inclusion(:status, @statuses)
    |> validate_payload_no_credentials()
    |> validate_payload_size()
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:agent_id)
  end

  defp validate_payload_no_credentials(changeset) do
    case get_field(changeset, :payload) do
      payload when is_map(payload) ->
        offending =
          payload
          |> Map.keys()
          |> Enum.find(fn k -> Regex.match?(@forbidden_key_re, to_string(k)) end)

        case offending do
          nil ->
            changeset

          key ->
            add_error(
              changeset,
              :payload,
              "key #{inspect(key)} looks like a credential — credentials must never enter trigger payloads"
            )
        end

      _ ->
        changeset
    end
  end

  defp validate_payload_size(changeset) do
    case get_field(changeset, :payload) do
      payload when is_map(payload) ->
        size =
          case Jason.encode(payload) do
            {:ok, encoded} -> byte_size(encoded)
            _ -> 0
          end

        if size > @max_payload_bytes do
          add_error(
            changeset,
            :payload,
            "encoded payload size #{size} exceeds #{@max_payload_bytes} bytes"
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end

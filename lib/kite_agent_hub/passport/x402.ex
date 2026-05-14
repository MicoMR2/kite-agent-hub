defmodule KiteAgentHub.Passport.X402 do
  @moduledoc """
  x402 fee-gate helpers for Rail B agents.

  Two surfaces:
    * `payment_required_response/1` — server-controlled 402 body that
      KAH returns when an agent without a payment receipt hits a
      gated endpoint. Inputs come from `VaultConfig.address/0`,
      `ChainId.default/0`, and a fixed resource descriptor — never
      from the request.
    * `verify_receipt/1` — sanity-validates an `X-Payment-Receipt`
      header. Hackathon scope: format + payee match against the
      configured vault. Signature crypto verification is deferred
      until the Passport backend's signing spec is finalized; until
      then we log every accepted receipt at warning level so the
      unsigned path is auditable.
  """

  require Logger

  alias KiteAgentHub.Kite.{ChainId, VaultConfig}

  @max_receipt_bytes 4096

  # Resource path the 402 body advertises. Server-side constant —
  # callers never get to choose it (CyberSec ask #4 from msg 9076).
  @resource_descriptor "/api/v1/trades"

  # Hackathon fee. Zero today; flipped post-hackathon via config.
  @default_fee_usdc Decimal.new("0.00")

  @doc """
  Active per-trade x402 fee. Single source of truth shared by the 402
  response builder and the controller-side zero-fee bypass (CyberSec
  9769 / 9774). When this returns `0.00`, the controller skips receipt
  enforcement; any non-zero value requires a valid X-Payment-Receipt.
  Post-hackathon this becomes runtime config (Application.get_env or
  DB-backed) — separate PR + re-audit at that point.
  """
  @spec current_fee() :: Decimal.t()
  def current_fee, do: @default_fee_usdc

  @doc """
  Build the 402 envelope KAH returns when a per-trade agent posts a
  trade without a valid receipt. Returns `nil` when the vault
  address isn't configured — the controller should fall back to a
  503 in that case (Phorari direction msg 9079).
  """
  @spec payment_required_response(map()) :: map() | nil
  def payment_required_response(_agent) do
    case VaultConfig.address() do
      addr when is_binary(addr) and byte_size(addr) > 0 ->
        %{
          error: "payment_required",
          x402: %{
            scheme: "x402-v0",
            asset: "USDC",
            chain_id: ChainId.default(),
            amount: Decimal.to_string(current_fee()),
            payee: addr,
            resource: @resource_descriptor,
            description:
              "Per-trade fee to the KAH vault. Pay via your kpass session and retry with X-Payment-Receipt set."
          }
        }

      _ ->
        nil
    end
  end

  @doc """
  Validate an x402 receipt header. Returns:
    * `{:ok, %{receipt: raw, amount: decimal, payee: addr}}` on accept
    * `{:error, :missing}` when nil/empty
    * `{:error, :too_large}` when over the 4096-byte cap (CyberSec #5)
    * `{:error, :malformed}` when the JSON body can't be parsed
    * `{:error, :wrong_payee}` when the receipt's payee doesn't match
       the configured KAH vault (CyberSec #1)
    * `{:error, :vault_unconfigured}` when there's no KAH vault address
       on this instance (CyberSec #1 — reject all x402-required
       requests instead of silently accepting)
  """
  @spec verify_receipt(String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def verify_receipt(nil), do: {:error, :missing}
  def verify_receipt(""), do: {:error, :missing}

  def verify_receipt(receipt) when is_binary(receipt) do
    cond do
      byte_size(receipt) > @max_receipt_bytes ->
        {:error, :too_large}

      not VaultConfig.configured?() ->
        {:error, :vault_unconfigured}

      true ->
        with {:ok, decoded} <- decode_receipt(receipt),
             {:ok, payee} <- fetch_payee(decoded),
             :ok <- check_payee(payee),
             {:ok, amount} <- fetch_amount(decoded) do
          # TODO: PR-X — replace this format-only check with proper
          # signature verification against the Passport-backend
          # signing key. Until then we log every accept so the
          # unsigned path is auditable. (CyberSec ask #2.)
          Logger.warning(
            "x402-unsigned-accept TODO: PR-X crypto verify — payee=#{payee} amount=#{amount}"
          )

          {:ok, %{receipt: receipt, amount: amount, payee: payee}}
        end
    end
  end

  def verify_receipt(_), do: {:error, :malformed}

  ## ── Internals ──────────────────────────────────────────────────────────

  defp decode_receipt(receipt) do
    case Base.decode64(receipt) do
      {:ok, raw_json} ->
        case Jason.decode(raw_json) do
          {:ok, %{} = body} -> {:ok, body}
          _ -> {:error, :malformed}
        end

      _ ->
        # Some clients send raw JSON rather than base64-wrapped.
        # Accept that shape too for hackathon convenience; the
        # signature gate that's coming will tighten it back.
        case Jason.decode(receipt) do
          {:ok, %{} = body} -> {:ok, body}
          _ -> {:error, :malformed}
        end
    end
  end

  defp fetch_payee(%{"payee" => p}) when is_binary(p), do: {:ok, p}
  defp fetch_payee(_), do: {:error, :malformed}

  defp check_payee(payee) do
    case VaultConfig.address() do
      addr when is_binary(addr) and addr != "" ->
        if String.downcase(payee) == String.downcase(addr),
          do: :ok,
          else: {:error, :wrong_payee}

      _ ->
        # Belt-and-suspenders — verify_receipt/1 already checked
        # configured? above, but if env was unset between the two
        # reads we still bail rather than accept.
        {:error, :vault_unconfigured}
    end
  end

  defp fetch_amount(%{"amount" => a}) when is_binary(a) or is_number(a) do
    case Decimal.parse(to_string(a)) do
      {dec, _} -> {:ok, dec}
      :error -> {:error, :malformed}
    end
  end

  defp fetch_amount(_), do: {:ok, @default_fee_usdc}
end

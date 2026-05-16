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

  # Chain-aware hackathon fees. Testnet is always free (judge sandbox
  # + paper-trading tier). Mainnet is the paid rail but stays at 0.00
  # until Mico flips the activation toggle post-hackathon — see
  # Phorari 9818 + CyberSec 9808. Catch-all is fail-safe (free, not
  # paid) so an unknown chain can never silently start charging.
  @testnet_chain_id 2368
  @mainnet_chain_id 2366
  @testnet_fee_usdc Decimal.new("0.00")
  @mainnet_fee_usdc Decimal.new("0.00")
  @fallback_fee_usdc Decimal.new("0.00")

  @doc """
  Active per-trade x402 fee for the given chain. Single source of truth
  shared by the 402 response builder and the controller/worker zero-fee
  bypasses (CyberSec 9769 / 9774 / 9808). When this returns `0.00`,
  callers skip receipt enforcement; any non-zero value requires a valid
  X-Payment-Receipt.

  Phorari 9818 spec: explicit testnet/mainnet clauses with a fail-safe
  catch-all that defaults to free, not paid.
  """
  @spec current_fee(integer() | nil) :: Decimal.t()
  def current_fee(@testnet_chain_id), do: @testnet_fee_usdc
  def current_fee(@mainnet_chain_id), do: @mainnet_fee_usdc
  def current_fee(_), do: @fallback_fee_usdc

  @doc """
  Backwards-compatible default-chain fee. Resolves the platform default
  chain via `ChainId.default/0` so existing tests/scripts that don't
  thread an agent through keep working.
  """
  @spec current_fee() :: Decimal.t()
  def current_fee, do: current_fee(ChainId.default())

  @doc """
  Build the 402 envelope KAH returns when a per-trade agent posts a
  trade without a valid receipt. Returns `nil` when the vault
  address isn't configured — the controller should fall back to a
  503 in that case (Phorari direction msg 9079).
  """
  @spec payment_required_response(map()) :: map() | nil
  def payment_required_response(agent) do
    chain_id = agent_chain_id(agent)

    case VaultConfig.address() do
      addr when is_binary(addr) and byte_size(addr) > 0 ->
        %{
          error: "payment_required",
          x402: %{
            scheme: "x402-v0",
            asset: "USDC",
            chain_id: chain_id,
            amount: Decimal.to_string(current_fee(chain_id)),
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

  # Per-agent chain resolution with fallback to the platform default.
  # An agent row with a nil/missing chain_id (legacy seeds, fresh
  # inserts) falls back to ChainId.default/0 — same precedence the rest
  # of the codebase uses (Contracts.rpc_url, KiteAttestationWorker).
  defp agent_chain_id(%{chain_id: cid}) when is_integer(cid), do: cid
  defp agent_chain_id(_), do: ChainId.default()

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

  # Receipts without an explicit amount are treated as paying the
  # platform-default chain's fee — keeps parsing backwards-compatible
  # with pre-chain-aware kpass clients.
  defp fetch_amount(_), do: {:ok, current_fee(ChainId.default())}
end

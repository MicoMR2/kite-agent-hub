defmodule KiteAgentHub.Passport.X402Test do
  use ExUnit.Case, async: false

  alias KiteAgentHub.Passport.X402

  @vault "0xFC74b669CF7c1676feeD4Fea99A8d9fE2FAd3465"
  @other "0x0000000000000000000000000000000000000001"

  setup do
    prior = Application.get_env(:kite_agent_hub, :kah_vault_address)
    Application.put_env(:kite_agent_hub, :kah_vault_address, @vault)
    on_exit(fn -> Application.put_env(:kite_agent_hub, :kah_vault_address, prior) end)
    :ok
  end

  describe "payment_required_response/1" do
    test "builds server-controlled 402 envelope when vault is configured" do
      assert %{x402: x402} = X402.payment_required_response(%{id: "any"})
      assert x402.scheme == "x402-v0"
      assert x402.asset == "USDC"
      assert x402.payee == @vault
      assert x402.resource == "/api/v1/trades"
    end

    test "returns nil when the vault env is missing" do
      Application.put_env(:kite_agent_hub, :kah_vault_address, nil)
      assert X402.payment_required_response(%{id: "any"}) == nil
    end
  end

  describe "verify_receipt/1" do
    defp receipt(payee, amount \\ "0.00") do
      %{"payee" => payee, "amount" => amount, "resource" => "/api/v1/trades"}
      |> Jason.encode!()
      |> Base.encode64()
    end

    test "accepts a well-formed receipt with the configured payee" do
      assert {:ok, %{payee: @vault, amount: %Decimal{}}} =
               X402.verify_receipt(receipt(@vault))
    end

    test "rejects mismatched payee" do
      assert {:error, :wrong_payee} = X402.verify_receipt(receipt(@other))
    end

    test "rejects missing receipt" do
      assert {:error, :missing} = X402.verify_receipt(nil)
      assert {:error, :missing} = X402.verify_receipt("")
    end

    test "rejects oversize receipt (cap at 4096 bytes)" do
      blob = String.duplicate("a", 5000)
      assert {:error, :too_large} = X402.verify_receipt(blob)
    end

    test "rejects malformed receipt" do
      assert {:error, :malformed} = X402.verify_receipt("not-base64-or-json")
    end

    test "rejects when vault is unconfigured" do
      Application.put_env(:kite_agent_hub, :kah_vault_address, nil)
      assert {:error, :vault_unconfigured} = X402.verify_receipt(receipt(@vault))
    end

    test "accepts a raw-JSON receipt (no base64 wrapper)" do
      raw = Jason.encode!(%{"payee" => @vault, "amount" => "0.00"})
      assert {:ok, %{payee: @vault}} = X402.verify_receipt(raw)
    end
  end
end

defmodule KiteAgentHub.Credentials.Cipher do
  @moduledoc """
  AES-256-GCM encryption for API credential secrets.

  Encryption key is read from the `CREDENTIAL_ENCRYPTION_KEY` env var at
  runtime — a 64-char hex string (32 bytes). Set this as a Fly secret:

      fly secrets set CREDENTIAL_ENCRYPTION_KEY=$(openssl rand -hex 32)

  Falls back to a key derived from SECRET_KEY_BASE in development.
  """

  @aad "kite_credential_v1"

  @doc "Encrypt plaintext. Returns {ciphertext, iv, tag} — all binaries."
  def encrypt(plaintext) when is_binary(plaintext) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)
    {ciphertext, iv, tag}
  end

  @doc "Decrypt {ciphertext, iv, tag}. Returns {:ok, plaintext} or {:error, :decryption_failed}."
  def decrypt(ciphertext, iv, tag) do
    key = encryption_key()
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  defp encryption_key do
    case System.get_env("CREDENTIAL_ENCRYPTION_KEY") do
      nil ->
        # Dev fallback: derive 32 bytes from SECRET_KEY_BASE
        base = Application.get_env(:kite_agent_hub, KiteAgentHubWeb.Endpoint)[:secret_key_base] || ""
        :crypto.hash(:sha256, base)

      hex when byte_size(hex) >= 64 ->
        Base.decode16!(binary_part(hex, 0, 64), case: :mixed)

      _short ->
        # Misconfigured key — fall back to dev key and log a warning
        require Logger
        Logger.warning("Cipher: CREDENTIAL_ENCRYPTION_KEY must be >= 64 hex chars. Using dev fallback.")
        base = Application.get_env(:kite_agent_hub, KiteAgentHubWeb.Endpoint)[:secret_key_base] || ""
        :crypto.hash(:sha256, base)
    end
  end
end

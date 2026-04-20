defmodule KiteAgentHub.Kite.LLM.Provider do
  @moduledoc """
  Behaviour for LLM providers that power `SignalEngine`.

  Each implementation wraps a single vendor (Anthropic, OpenAI, a
  local Ollama server, etc.) and returns the generated text as a
  plain string. Parsing the JSON signal is the caller's job; the
  provider only has to speak HTTP and hand back the model output.

  Expected `opts` keys:

    * `:model` — vendor-specific model identifier (required for
      OpenAI + Anthropic; Ollama also requires it as the local tag,
      e.g. `"llama3.1:8b"`)
    * `:api_key` — decrypted secret from
      `KiteAgentHub.Credentials.fetch_llm_key/2` (Anthropic/OpenAI)
    * `:base_url` — overrides the default endpoint (Ollama only)
    * `:max_tokens` — optional per-call cap

  Return values:

    * `{:ok, text}` on success
    * `{:error, reason}` on vendor-reported failure or transport
      error. Providers must never raise on timeout/401/bad-JSON;
      callers rely on `{:error, _}` to fall through.
  """

  @callback chat(prompt :: String.t(), opts :: map()) ::
              {:ok, String.t()} | {:error, term()}
end

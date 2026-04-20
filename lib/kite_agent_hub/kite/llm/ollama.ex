defmodule KiteAgentHub.Kite.LLM.Ollama do
  @moduledoc """
  Ollama local-model implementation of
  `KiteAgentHub.Kite.LLM.Provider`.

  The base URL is read from application config (`:ollama_base_url`)
  or the `OLLAMA_BASE_URL` env var at runtime — **never from
  per-agent or per-org input**. That keeps the SSRF surface flat:
  the deployer picks which Ollama instance this node can reach, and
  agents can only point at that one.

  Per-agent `llm_endpoint_url` is introduced in a later PR and will
  go through its own SSRF allow-list (https scheme, block RFC-1918
  + link-local) before it can override this default.
  """

  @behaviour KiteAgentHub.Kite.LLM.Provider

  require Logger

  @default_base_url "http://localhost:11434"
  @default_model "llama3.1:8b"

  @impl true
  def chat(prompt, opts) do
    model = Map.get(opts, :model) || @default_model
    base_url = base_url()

    body = %{
      model: model,
      stream: false,
      messages: [%{role: "user", content: prompt}]
    }

    try do
      case Req.post(base_url <> "/api/chat",
             json: body,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"message" => %{"content" => text}}}} ->
          {:ok, text}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("LLM.Ollama: #{status} response — #{inspect(resp_body)}")
          {:error, {:http_status, status}}

        {:error, reason} ->
          Logger.warning("LLM.Ollama: request failed — #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("LLM.Ollama: raised — #{Exception.message(e)}")
        {:error, :provider_exception}
    end
  end

  # Base URL precedence:
  #   1. app config :ollama_base_url (set in config/runtime.exs from
  #      OLLAMA_BASE_URL for Fly-hosted Ollama)
  #   2. hard-coded localhost default for `mix phx.server` dev
  defp base_url do
    Application.get_env(:kite_agent_hub, :ollama_base_url) || @default_base_url
  end
end

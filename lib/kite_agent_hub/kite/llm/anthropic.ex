defmodule KiteAgentHub.Kite.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API implementation of `KiteAgentHub.Kite.LLM.Provider`.

  Lifts the existing `SignalEngine.call_claude/2` verbatim so the
  shim fallback (decommissioning in PR D) and the per-org path both
  hit identical behaviour.
  """

  @behaviour KiteAgentHub.Kite.LLM.Provider

  require Logger

  @endpoint "https://api.anthropic.com/v1/messages"
  @default_model "claude-haiku-4-5-20251001"
  @default_max_tokens 512

  @impl true
  def chat(prompt, opts) do
    api_key = Map.fetch!(opts, :api_key)
    model = Map.get(opts, :model) || @default_model
    max_tokens = Map.get(opts, :max_tokens, @default_max_tokens)

    body = %{
      model: model,
      max_tokens: max_tokens,
      messages: [%{role: "user", content: prompt}]
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    try do
      case Req.post(@endpoint, json: body, headers: headers, receive_timeout: 15_000) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, text}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("LLM.Anthropic: #{status} response — #{inspect(resp_body)}")
          {:error, {:http_status, status}}

        {:error, reason} ->
          Logger.warning("LLM.Anthropic: request failed — #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("LLM.Anthropic: raised — #{Exception.message(e)}")
        {:error, :provider_exception}
    end
  end
end

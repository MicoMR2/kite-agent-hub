defmodule KiteAgentHub.Kite.LLM.OpenAI do
  @moduledoc """
  OpenAI chat-completions implementation of
  `KiteAgentHub.Kite.LLM.Provider`. Bearer auth, JSON body, same
  `{:ok, text}` / `{:error, reason}` contract as every other
  provider.
  """

  @behaviour KiteAgentHub.Kite.LLM.Provider

  require Logger

  @endpoint "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o-mini"
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
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]

    try do
      case Req.post(@endpoint, json: body, headers: headers, receive_timeout: 15_000) do
        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => text}} | _]}
         }} ->
          {:ok, text}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("LLM.OpenAI: #{status} response — #{inspect(resp_body)}")
          {:error, {:http_status, status}}

        {:error, reason} ->
          Logger.warning("LLM.OpenAI: request failed — #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("LLM.OpenAI: raised — #{Exception.message(e)}")
        {:error, :provider_exception}
    end
  end
end

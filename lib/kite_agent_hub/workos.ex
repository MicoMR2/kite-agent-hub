defmodule KiteAgentHub.WorkOS do
  @moduledoc """
  WorkOS AuthKit integration using Req (no SDK).

  Handles OAuth 2.0 authorization code flow for user authentication.
  Docs: https://workos.com/docs/user-management
  """

  @base_url "https://api.workos.com"
  @provider "authkit"

  defp client_id, do: Application.fetch_env!(:kite_agent_hub, :workos_client_id)
  defp api_key, do: Application.fetch_env!(:kite_agent_hub, :workos_api_key)
  defp redirect_uri, do: Application.fetch_env!(:kite_agent_hub, :workos_redirect_uri)

  @doc """
  Returns the WorkOS authorization URL to redirect the user to.
  Generates a PKCE state value for CSRF protection.
  """
  def authorization_url(state \\ nil) do
    params = %{
      client_id: client_id(),
      redirect_uri: redirect_uri(),
      response_type: "code",
      provider: @provider,
      state: state || :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    }

    query = URI.encode_query(params)
    "#{@base_url}/user_management/authorize?#{query}"
  end

  @doc """
  Exchanges an authorization code for a user profile.

  Returns `{:ok, %{workos_id, email, first_name, last_name}}` or `{:error, reason}`.
  """
  def authenticate_with_code(code) do
    body = %{
      client_id: client_id(),
      client_secret: api_key(),
      redirect_uri: redirect_uri(),
      grant_type: "authorization_code",
      code: code
    }

    case Req.post("#{@base_url}/user_management/authenticate", json: body) do
      {:ok, %{status: 200, body: %{"user" => user}}} ->
        {:ok,
         %{
           workos_id: user["id"],
           email: user["email"],
           first_name: user["first_name"],
           last_name: user["last_name"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "WorkOS error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end

defmodule KiteAgentHub.Repo do
  use Ecto.Repo,
    otp_app: :kite_agent_hub,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Executes `fun` inside a transaction with `app.current_user_id` set
  to `user_id` for the duration of the transaction. All Postgres RLS
  policies read this value — call this wrapper around any query that
  must be tenant-scoped.

  ## Example

      Repo.with_user(current_scope.user.id, fn ->
        Repo.all(KiteAgent)
      end)
  """
  def with_user(user_id, fun) when is_integer(user_id) do
    with_user(Integer.to_string(user_id), fun)
  end

  def with_user(user_id, fun) when is_binary(user_id) do
    transaction(fn ->
      query!(
        "SELECT set_config('app.current_user_id', $1, true)",
        [user_id]
      )

      fun.()
    end)
  end
end

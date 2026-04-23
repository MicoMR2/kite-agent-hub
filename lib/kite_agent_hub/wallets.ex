defmodule KiteAgentHub.Wallets do
  @moduledoc """
  Context for user wallets — the USD balance attached to a user's
  account. Balance is server-owned: no function here accepts a raw
  balance value from a client. All public read paths take a
  `%User{}` so queries stay scoped to the caller.
  """

  import Ecto.Query
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Accounts.User
  alias KiteAgentHub.Wallets.Wallet

  @spec get_for_user(User.t()) :: Wallet.t() | nil
  def get_for_user(%User{id: user_id}) do
    Repo.get_by(Wallet, user_id: user_id)
  end

  @doc """
  Provision a zero-balance wallet for a user. Idempotent — safe to
  call twice. Intended for use inside the registration `Ecto.Multi`
  or a one-off backfill.
  """
  @spec provision_for_user(User.t()) :: {:ok, Wallet.t()} | {:error, Ecto.Changeset.t()}
  def provision_for_user(%User{id: user_id}) do
    case Repo.get_by(Wallet, user_id: user_id) do
      %Wallet{} = wallet ->
        {:ok, wallet}

      nil ->
        %{user_id: user_id}
        |> Wallet.create_changeset()
        |> Repo.insert()
    end
  end

  @doc """
  Credit the wallet by a positive amount. Server-only: callers are
  internal (Stripe webhook, crypto deposit watcher). No user input
  path reaches this function.
  """
  @spec credit(User.t(), Decimal.t()) :: {:ok, Wallet.t()} | {:error, term()}
  def credit(%User{id: user_id}, %Decimal{} = amount) do
    if Decimal.compare(amount, 0) == :gt do
      from(w in Wallet, where: w.user_id == ^user_id)
      |> Repo.one()
      |> case do
        nil ->
          {:error, :wallet_missing}

        wallet ->
          wallet
          |> Ecto.Changeset.change(balance_usd: Decimal.add(wallet.balance_usd, amount))
          |> Repo.update()
      end
    else
      {:error, :non_positive_amount}
    end
  end
end

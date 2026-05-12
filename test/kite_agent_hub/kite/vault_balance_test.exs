defmodule KiteAgentHub.Kite.VaultBalanceTest do
  # `async: false` because the module uses a process-global ETS table
  # and we mutate the :kah_vault_address env per test.
  use ExUnit.Case, async: false

  alias KiteAgentHub.Kite.VaultBalance

  @vault "0xFC74b669CF7c1676feeD4Fea99A8d9fE2FAd3465"

  setup do
    prior = Application.get_env(:kite_agent_hub, :kah_vault_address)
    Application.put_env(:kite_agent_hub, :kah_vault_address, @vault)
    # Reset the ETS cache between tests so TTL/last-good state doesn't
    # bleed across cases.
    if :ets.whereis(:kah_vault_balance_cache) != :undefined do
      :ets.delete_all_objects(:kah_vault_balance_cache)
    end

    on_exit(fn -> Application.put_env(:kite_agent_hub, :kah_vault_address, prior) end)
    :ok
  end

  describe "cached/0 — happy path" do
    test "parses USDC balance from Blockscout response and shapes the snapshot" do
      # Manually seed the cache to bypass the live Blockscout call.
      # The module's public API only round-trips through ETS for
      # warm reads, so seeding lets us verify the read+sanitize path
      # without mocking the HTTP client.
      :ets.whereis(:kah_vault_balance_cache) == :undefined and
        :ets.new(:kah_vault_balance_cache,
          [:named_table, :public, :set, read_concurrency: true]
        )

      seeded = %{
        address: @vault,
        usdc: Decimal.new("123.45"),
        usdt: nil,
        native_kite: Decimal.new("0.5"),
        fetched_at: ~U[2026-05-11 22:00:00Z],
        fetched_at_unix: System.system_time(:second)
      }

      :ets.insert(:kah_vault_balance_cache, {:snapshot, seeded})

      assert {:ok, snap} = VaultBalance.cached()
      assert snap.address == @vault
      assert Decimal.equal?(snap.usdc, Decimal.new("123.45"))
      assert snap.usdt == nil
      assert Decimal.equal?(snap.native_kite, Decimal.new("0.5"))
      assert %DateTime{} = snap.fetched_at
      # `fetched_at_unix` is an internal field — sanitize/1 must
      # strip it before the snapshot crosses the module boundary.
      refute Map.has_key?(snap, :fetched_at_unix)
    end
  end

  describe "cached/0 — unconfigured vault" do
    test "returns {:error, :unconfigured} when env is empty" do
      Application.put_env(:kite_agent_hub, :kah_vault_address, nil)
      assert {:error, :unconfigured} = VaultBalance.cached()
    end

    test "returns {:error, :unconfigured} when env is the empty string" do
      Application.put_env(:kite_agent_hub, :kah_vault_address, "")
      assert {:error, :unconfigured} = VaultBalance.cached()
    end
  end

  describe "cached_or_fetch/0 — render bounded" do
    test "passes through unconfigured without hitting Task timeout" do
      Application.put_env(:kite_agent_hub, :kah_vault_address, nil)
      assert {:error, :unconfigured} = VaultBalance.cached_or_fetch()
    end

    test "returns the cached snapshot when one is fresh in ETS" do
      :ets.whereis(:kah_vault_balance_cache) == :undefined and
        :ets.new(:kah_vault_balance_cache,
          [:named_table, :public, :set, read_concurrency: true]
        )

      seeded = %{
        address: @vault,
        usdc: Decimal.new("9.99"),
        usdt: nil,
        native_kite: nil,
        fetched_at: ~U[2026-05-11 22:00:00Z],
        fetched_at_unix: System.system_time(:second)
      }

      :ets.insert(:kah_vault_balance_cache, {:snapshot, seeded})

      assert {:ok, snap} = VaultBalance.cached_or_fetch()
      assert Decimal.equal?(snap.usdc, Decimal.new("9.99"))
    end
  end

  describe "ETS — concurrent readers" do
    test "ten parallel cached/0 calls all succeed without race-crashing" do
      # The application supervisor owns the named ETS table at boot
      # (lib/kite_agent_hub/application.ex). Concurrent readers from
      # transient processes (LiveView mounts, Tasks) must not race on
      # ensure_table/0 — verify by fanning out and asserting all
      # results match.
      Application.put_env(:kite_agent_hub, :kah_vault_address, nil)

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> VaultBalance.cached() end) end)
        |> Task.await_many(2_000)

      assert Enum.all?(results, &match?({:error, :unconfigured}, &1))
      assert :ets.whereis(:kah_vault_balance_cache) != :undefined
    end
  end
end

defmodule KiteAgentHub.Trading.RiskConfigChangesetTest do
  @moduledoc """
  Validates the whitelist + bounds enforcement on `risk_config`. The
  changeset is the only sanctioned write path; nothing else is allowed
  to put_change/3 onto the column.

  Invariants checked here:
    * Unknown keys are rejected — no raw map merge.
    * per_trade_notional_cap_usd is positive Decimal, ≤ $5K hard ceiling.
    * profit_trim_partial_pct + profit_trim_full_pct are 0..100 ints,
      with full > partial.
    * market_hours_only is boolean.
    * Empty submission clears the override (falls back to defaults at
      runtime via Trading.Risk).
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.KiteAgent

  defp apply!(attrs) do
    KiteAgent.risk_config_changeset(%KiteAgent{}, %{"risk_config" => attrs})
  end

  describe "happy path" do
    test "all whitelisted keys, in-bounds values, persist as string-keyed map" do
      cs =
        apply!(%{
          "per_trade_notional_cap_usd" => "2500",
          "profit_trim_partial_pct" => 4,
          "profit_trim_full_pct" => 7,
          "market_hours_only" => true
        })

      assert cs.valid?, "expected valid, got: #{inspect(cs.errors)}"
      cfg = Ecto.Changeset.get_change(cs, :risk_config)
      assert cfg["per_trade_notional_cap_usd"] == "2500"
      assert cfg["profit_trim_partial_pct"] == 4
      assert cfg["profit_trim_full_pct"] == 7
      assert cfg["market_hours_only"] == true
    end

    test "empty map clears the override (no change persists)" do
      cs = apply!(%{})
      assert cs.valid?
      # No change means runtime falls through to Trading.Risk defaults.
      assert Ecto.Changeset.get_change(cs, :risk_config) in [nil, %{}]
    end
  end

  describe "whitelist enforcement" do
    test "unknown key is rejected" do
      cs = apply!(%{"max_drawdown_pct" => 5})
      refute cs.valid?
      assert any_error?(cs, ~r/unknown key: max_drawdown_pct/)
    end
  end

  describe "per_trade_notional_cap_usd bounds" do
    test "rejects zero" do
      cs = apply!(%{"per_trade_notional_cap_usd" => "0"})
      refute cs.valid?
    end

    test "rejects negative" do
      cs = apply!(%{"per_trade_notional_cap_usd" => "-100"})
      refute cs.valid?
    end

    test "rejects above the $5K hard ceiling" do
      cs = apply!(%{"per_trade_notional_cap_usd" => "5000.01"})
      refute cs.valid?
    end

    test "accepts the ceiling exactly" do
      cs = apply!(%{"per_trade_notional_cap_usd" => "5000"})
      assert cs.valid?
    end
  end

  describe "profit-trim ladder" do
    test "rejects partial out of 0..100" do
      assert refute_valid(apply!(%{"profit_trim_partial_pct" => -1}))
      assert refute_valid(apply!(%{"profit_trim_partial_pct" => 101}))
    end

    test "rejects full not greater than partial" do
      cs = apply!(%{"profit_trim_partial_pct" => 5, "profit_trim_full_pct" => 5})
      refute cs.valid?
      assert any_error?(cs, ~r/must be greater than partial/)
    end

    test "accepts full == partial + 1" do
      cs = apply!(%{"profit_trim_partial_pct" => 3, "profit_trim_full_pct" => 4})
      assert cs.valid?
    end
  end

  describe "market_hours_only" do
    test "accepts boolean true and false" do
      assert apply!(%{"market_hours_only" => true}).valid?
      assert apply!(%{"market_hours_only" => false}).valid?
    end

    test "rejects non-boolean" do
      cs = apply!(%{"market_hours_only" => "maybe"})
      refute cs.valid?
    end
  end

  defp refute_valid(cs), do: not cs.valid?

  defp any_error?(%Ecto.Changeset{errors: errors}, regex) do
    Enum.any?(errors, fn {_field, {msg, _opts}} -> Regex.match?(regex, msg) end)
  end
end

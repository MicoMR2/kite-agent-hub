defmodule KiteAgentHub.CollectiveIntelligence.MethodSeederStubsTest do
  @moduledoc """
  Confirms the M-011 → M-017 stub predicates return false and the
  existing M-007 entry point is untouched. Real backtest logic for
  the stubs ships in per-method follow-on PRs.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.CollectiveIntelligence.MethodSeeder

  test "M-011 → M-017 stubs return false regardless of input" do
    bars = Enum.map(1..50, fn i -> %{c: 1.0 + i * 0.001} end)

    refute MethodSeeder.m011_conditions_met?(bars)
    refute MethodSeeder.m012_conditions_met?(bars)
    refute MethodSeeder.m013_conditions_met?(bars)
    refute MethodSeeder.m014_conditions_met?(bars)
    refute MethodSeeder.m015_conditions_met?(bars)
    refute MethodSeeder.m016_conditions_met?(bars)
    refute MethodSeeder.m017_conditions_met?(bars)
  end

  test "M-011 → M-017 stubs accept opts without crashing" do
    bars = Enum.map(1..50, fn i -> %{c: 1.0 + i * 0.001} end)
    opts = [foo: :bar, min_bars: 30]

    refute MethodSeeder.m011_conditions_met?(bars, opts)
    refute MethodSeeder.m017_conditions_met?(bars, opts)
  end

  test "M-007 still functions after stub additions" do
    # Flat series → very low realised vol → conditions should be met.
    bars = Enum.map(1..30, fn _ -> %{c: 1.1234} end)
    assert MethodSeeder.m007_conditions_met?(bars)

    # Volatile series → high realised vol → conditions should NOT be met.
    bars_volatile =
      Enum.map(1..30, fn i ->
        %{c: 1.0 + :math.sin(i) * 0.05}
      end)

    refute MethodSeeder.m007_conditions_met?(bars_volatile)
  end
end

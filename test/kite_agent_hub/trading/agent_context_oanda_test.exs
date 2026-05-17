defmodule KiteAgentHub.Trading.AgentContextOandaTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.AgentContext
  alias KiteAgentHub.Trading.KiteAgent

  test "trading prompt includes OANDA playbook by default" do
    agent = %KiteAgent{
      id: "test-agent-id",
      name: "TestAgent",
      api_token: "tok_test",
      organization_id: nil,
      agent_type: "trading"
    }

    context = AgentContext.generate(agent)

    assert context =~ "OANDA (Forex Practice)"
    assert context =~ "M-011"
    assert context =~ "M-017"
    assert context =~ "London Open Breakout"
    assert context =~ "Net USD exposure"
    assert context =~ "Marcus"
  end

  test "research prompt also includes OANDA playbook" do
    agent = %KiteAgent{
      id: "test-agent-id",
      name: "TestResearch",
      api_token: "tok_test",
      organization_id: nil,
      agent_type: "research"
    }

    context = AgentContext.generate(agent)

    assert context =~ "OANDA (Forex Practice)"
    assert context =~ "M-014"
  end

  test "omitting :oanda from platforms suppresses the section" do
    agent = %KiteAgent{
      id: "test-agent-id",
      name: "TestNoForex",
      api_token: "tok_test",
      organization_id: nil,
      agent_type: "trading"
    }

    context = AgentContext.generate(agent, platforms: [:alpaca, :kalshi])

    refute context =~ "OANDA (Forex Practice)"
    refute context =~ "M-011"
  end
end

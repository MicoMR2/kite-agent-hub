defmodule KiteAgentHubWeb.CodexPromptsTest do
  use ExUnit.Case, async: true

  alias KiteAgentHubWeb.CodexPrompts

  test "combined block never includes the agent api token" do
    agent = %{agent_type: "trading", api_token: "kite_secret_token_that_must_not_render"}

    block = CodexPrompts.combined_block(agent)

    refute block =~ agent.api_token
    assert block =~ "Paste KAH agent token"
    assert block =~ "export KAH_API_TOKEN"
    assert block =~ "codex '"
  end

  test "embedded prompts stay shell-safe for single-quoted codex command" do
    refute CodexPrompts.prompts_have_single_quotes?()
  end
end

defmodule KiteAgentHubWeb.CodexPrompts do
  @moduledoc """
  Self-contained Codex Terminal prompts for KAH agents.

  The three .md prompt files in `plugins/kite-agent-hub-agent/prompts/`
  are embedded at compile time via `@external_resource` so the rendered
  Option B "Run with Codex Terminal" block does not require the user to
  clone the repo or run a script. The site serves the full prompt string
  directly into a `codex '<prompt>'` shell command.

  CyberSec guardrail (PR #217 msg 7733): the prompt path is resolved via
  explicit `case` on the agent_type value — never via string
  interpolation — so a tampered DB value cannot traverse outside the
  plugins directory. The interpolated `codex '...'` argument is built
  from a static template + agent_type only; no user-controlled freeform
  input (agent.name, etc.) is concatenated into the shell argument.
  """

  @prompts_dir Path.expand("../../plugins/kite-agent-hub-agent/prompts", __DIR__)

  @research_path Path.join(@prompts_dir, "research-test-agent.codex.md")
  @conversational_path Path.join(@prompts_dir, "conversational-agent.codex.md")
  @trading_path Path.join(@prompts_dir, "trading-agent.codex.md")

  @external_resource @research_path
  @external_resource @conversational_path
  @external_resource @trading_path

  @research_prompt File.read!(@research_path)
  @conversational_prompt File.read!(@conversational_path)
  @trading_prompt File.read!(@trading_path)

  @token_placeholder "kite_your_token_here"

  @doc """
  Returns the embedded prompt body for the given agent. The agent_type
  field is matched explicitly — anything else falls back to the
  research prompt (read-only). Never interpolates the field into a path.
  """
  def prompt_for(%{agent_type: "trading"}), do: @trading_prompt
  def prompt_for(%{agent_type: "conversational"}), do: @conversational_prompt
  def prompt_for(_), do: @research_prompt

  @doc """
  Single-line export command. Token is the agent's api_token, falling
  back to a placeholder so the rendered block is meaningful even before
  Reveal.
  """
  def export_command(agent) do
    token =
      case agent do
        %{api_token: t} when is_binary(t) and byte_size(t) > 0 -> t
        _ -> @token_placeholder
      end

    ~s|export KAH_API_TOKEN="#{token}"|
  end

  @doc """
  `codex '<prompt>'` — wraps the embedded prompt in single quotes.
  Prompt files do not contain a single quote, so this is shell-safe;
  the `prompts_have_single_quotes?/0` test asserts that invariant.
  """
  def codex_command(agent) do
    prompt = prompt_for(agent)
    "codex '" <> prompt <> "'"
  end

  @doc """
  Combined two-line copy block (token export then codex invocation).
  """
  def combined_block(agent) do
    export_command(agent) <> "\n" <> codex_command(agent)
  end

  @doc """
  Test invariant — the embedded prompts must not contain single quotes,
  otherwise the `codex '...'` shell argument will break.
  """
  def prompts_have_single_quotes? do
    String.contains?(@research_prompt, "'") or
      String.contains?(@conversational_prompt, "'") or
      String.contains?(@trading_prompt, "'")
  end

  def agent_type_label(%{agent_type: "trading"}), do: "Trade Agent"
  def agent_type_label(%{agent_type: "conversational"}), do: "Conversational Agent"
  def agent_type_label(_), do: "Research Agent"

  def can_trade?(%{agent_type: "trading"}), do: true
  def can_trade?(_), do: false
end

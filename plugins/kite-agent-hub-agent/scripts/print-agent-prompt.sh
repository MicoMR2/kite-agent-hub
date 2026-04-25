#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_TYPE="${1:-research}"

case "$AGENT_TYPE" in
  research)
    PROMPT_FILE="$ROOT_DIR/prompts/research-test-agent.codex.md"
    ;;
  conversational|conversation|chat|strategy|strategy-advisor)
    PROMPT_FILE="$ROOT_DIR/prompts/conversational-agent.codex.md"
    ;;
  trading|trade)
    PROMPT_FILE="$ROOT_DIR/prompts/trading-agent.codex.md"
    ;;
  *)
    echo "Unknown agent type: $AGENT_TYPE" >&2
    echo "Use one of: research, conversational, trading" >&2
    exit 1
    ;;
esac

if [[ -z "${KAH_API_TOKEN:-}" ]]; then
  echo "KAH_API_TOKEN is not set. Set it in your shell before running Codex."
  echo
fi

cat "$PROMPT_FILE"

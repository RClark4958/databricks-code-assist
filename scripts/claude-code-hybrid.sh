#!/bin/bash

# Claude Code via Databricks (Hybrid Launcher)
# Launches an isolated Claude Code instance routed through Databricks,
# preserving all consumer plugins without modifying the consumer installation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Ports
FILTER_PROXY_PORT=4001
LITELLM_PORT=4010
CLAUDE_MEM_PORT=37778

# Isolated home
CLAUDE_HOME="${PROJECT_ROOT}/.claude-code-home"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- Health check helper ---
check_proxy_health() {
    local healthy=true
    if ! curl -s "http://localhost:$FILTER_PROXY_PORT/health" 2>/dev/null | grep -q "healthy"; then
        healthy=false
    fi
    if ! curl -s -f "http://localhost:$LITELLM_PORT/health" >/dev/null 2>&1; then
        healthy=false
    fi
    $healthy
}

# --- Subcommands ---
case "${1:-}" in
    --status)
        echo -e "${CYAN}Proxy Status:${NC}"
        if curl -s "http://localhost:$FILTER_PROXY_PORT/health" 2>/dev/null | grep -q "healthy"; then
            echo -e "  Filter Proxy (:$FILTER_PROXY_PORT): ${GREEN}Running${NC}"
        else
            echo -e "  Filter Proxy (:$FILTER_PROXY_PORT): ${RED}Not running${NC}"
        fi
        if curl -s -f "http://localhost:$LITELLM_PORT/health" >/dev/null 2>&1; then
            echo -e "  LiteLLM (:$LITELLM_PORT):           ${GREEN}Running${NC}"
        else
            echo -e "  LiteLLM (:$LITELLM_PORT):           ${RED}Not running${NC}"
        fi
        echo ""
        echo -e "${CYAN}Isolation:${NC}"
        echo "  HOME:       $CLAUDE_HOME"
        echo "  claude-mem: port $CLAUDE_MEM_PORT"
        if [ -L "$CLAUDE_HOME/.claude/plugins" ]; then
            echo -e "  Plugins:    ${GREEN}symlinked${NC} -> $(readlink "$CLAUDE_HOME/.claude/plugins")"
        else
            echo -e "  Plugins:    ${RED}not configured${NC}"
        fi
        exit 0
        ;;
    --stop)
        echo "Stopping proxies..."
        [ -f "$PROJECT_ROOT/logs/filter_proxy.pid" ] && kill $(cat "$PROJECT_ROOT/logs/filter_proxy.pid") 2>/dev/null && echo "  Filter proxy stopped"
        [ -f "$PROJECT_ROOT/logs/litellm_claude.pid" ] && kill $(cat "$PROJECT_ROOT/logs/litellm_claude.pid") 2>/dev/null && echo "  LiteLLM stopped"
        rm -f "$PROJECT_ROOT/logs/filter_proxy.pid" "$PROJECT_ROOT/logs/litellm_claude.pid"
        echo "Done."
        exit 0
        ;;
    --help|-h)
        echo "Claude Code via Databricks (Hybrid)"
        echo ""
        echo "Usage: claude-code-hybrid.sh [OPTIONS] [CLAUDE_ARGS...]"
        echo ""
        echo "Options:"
        echo "  --status     Check proxy and isolation status"
        echo "  --stop       Stop the proxy servers"
        echo "  --help, -h   Show this help"
        echo ""
        echo "All other arguments are passed directly to Claude Code."
        echo ""
        echo "Setup: Run setup_claude_code_hybrid.sh first to initialize."
        exit 0
        ;;
esac

# --- Pre-flight checks ---
if [ ! -d "$CLAUDE_HOME/.claude" ]; then
    echo -e "${RED}Isolated HOME not found at $CLAUDE_HOME${NC}"
    echo "Run setup first: ./scripts/setup_claude_code_hybrid.sh <HOST> <TOKEN>"
    exit 1
fi

if ! check_proxy_health; then
    echo -e "${YELLOW}Proxies not running. Run setup first:${NC}"
    echo "  ./scripts/setup_claude_code_hybrid.sh <HOST> <TOKEN>"
    exit 1
fi

# --- Launch banner ---
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Claude Code via Databricks (Hybrid)             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}+${NC} Filter Proxy  :$FILTER_PROXY_PORT"
echo -e "  ${GREEN}+${NC} LiteLLM       :$LITELLM_PORT"
echo -e "  ${GREEN}+${NC} claude-mem    :$CLAUDE_MEM_PORT"
echo -e "  ${GREEN}+${NC} Plugins       symlinked"
echo ""

# --- Environment setup ---
# Save original HOME for reference
ORIGINAL_HOME="$HOME"

# Isolation: override HOME so Claude Code reads from .claude-code-home/
export HOME="$CLAUDE_HOME"

# Route all API calls through the filter proxy
export ANTHROPIC_BASE_URL="http://localhost:$FILTER_PROXY_PORT"
export ANTHROPIC_API_KEY="databricks-via-litellm"

# Prevent claude-mem port conflict with consumer instance
export CLAUDE_MEM_WORKER_PORT="$CLAUDE_MEM_PORT"

# Prevent any Anthropic authentication fallback
unset ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true

# Disable telemetry and non-essential traffic to Anthropic servers
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Auto-symlink dotfiles from real home (skip dirs/files that must stay isolated)
for f in "$ORIGINAL_HOME"/.*; do
    base=$(basename "$f")
    case "$base" in
        .|..|.Trash|.cache|.claude|.claude-*|.claude.json|.local|.npm|.vscode) continue ;;
    esac
    if [ ! -e "$CLAUDE_HOME/$base" ]; then
        ln -sf "$f" "$CLAUDE_HOME/$base"
    fi
done

# Launch Claude Code with all remaining arguments
exec claude --dangerously-skip-permissions "$@"

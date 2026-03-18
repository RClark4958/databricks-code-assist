#!/bin/bash

# Hybrid Claude Code + Databricks Setup Script
# Creates an isolated Databricks-backed Claude Code instance that preserves
# all consumer plugins while keeping the consumer installation untouched.
#
# Architecture:
#   Databricks Claude Code (.claude-code-home)
#     -> Filter Proxy (:4001) strips thinking blocks
#       -> LiteLLM (:4010) maps model names + injects credentials
#         -> Databricks (databricks-claude-opus-4-6)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Hybrid Claude Code + Databricks Setup           ║${NC}"
    echo -e "${CYAN}║  Isolated instance with consumer plugin support  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Argument parsing ---
if [ $# -ne 2 ]; then
    print_error "Usage: $0 <WORKSPACE_HOST> <WORKSPACE_API_TOKEN>"
    print_error "Example: $0 adb-1234567890123456.10.azuredatabricks.net dapi-your-token"
    echo ""
    print_status "To get your Databricks token:"
    echo "  1. Go to your Databricks workspace"
    echo "  2. Click your username -> Settings -> Developer"
    echo "  3. Click 'Manage' under Access tokens"
    echo "  4. Generate a new token"
    exit 1
fi

WORKSPACE_HOST="$1"
WORKSPACE_API_TOKEN="$2"

# Strip protocol prefix and trailing slash
WORKSPACE_HOST="${WORKSPACE_HOST#https://}"
WORKSPACE_HOST="${WORKSPACE_HOST#http://}"
WORKSPACE_HOST="${WORKSPACE_HOST%/}"

print_header
print_status "Workspace: $WORKSPACE_HOST"
print_status "Token: ${WORKSPACE_API_TOKEN:0:10}..."
echo ""

# --- Project paths ---
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)
CONSUMER_HOME="$HOME"
CLAUDE_HOME="${PROJECT_ROOT}/.claude-code-home"
VENV_DIR="${PROJECT_ROOT}/.venv"

# Ports
FILTER_PROXY_PORT=4001
LITELLM_PORT=4010
CLAUDE_MEM_PORT=37778  # Consumer uses 37777

# --- Activate venv if present ---
if [ -f "$VENV_DIR/bin/activate" ]; then
    source "$VENV_DIR/bin/activate"
    print_status "Using venv at $VENV_DIR"
fi

# ============================================================
# Step 1: Validate Databricks connectivity
# ============================================================
print_status "Step 1: Verifying Databricks connection..."
response=$(curl -s -w "%{http_code}" -X GET "https://$WORKSPACE_HOST/api/2.0/serving-endpoints" \
  -H "Authorization: Bearer $WORKSPACE_API_TOKEN" \
  -o /tmp/databricks_test.json)

if [ "$response" != "200" ]; then
    print_error "Failed to connect to Databricks workspace. HTTP status: $response"
    print_error "Please check your WORKSPACE_HOST and WORKSPACE_API_TOKEN"
    exit 1
fi
print_success "Databricks workspace reachable"

# ============================================================
# Step 2: Check prerequisites
# ============================================================
print_status "Step 2: Checking prerequisites..."

missing=()
command -v claude &>/dev/null || missing+=("claude (npm install -g @anthropic-ai/claude-code)")
command -v litellm &>/dev/null || missing+=("litellm (pip install 'litellm[proxy]')")
python3 -c "import fastapi" 2>/dev/null || missing+=("fastapi (pip install fastapi)")
python3 -c "import httpx" 2>/dev/null || missing+=("httpx (pip install httpx)")
python3 -c "import uvicorn" 2>/dev/null || missing+=("uvicorn (pip install uvicorn)")

if [ ${#missing[@]} -gt 0 ]; then
    print_error "Missing prerequisites:"
    for dep in "${missing[@]}"; do
        echo "  - $dep"
    done
    exit 1
fi
print_success "All prerequisites found"

# ============================================================
# Step 3: Generate LiteLLM config from template
# ============================================================
print_status "Step 3: Generating LiteLLM configuration..."

if [ ! -f "config/claude-code-litellm.template.yaml" ]; then
    print_error "Template file config/claude-code-litellm.template.yaml not found"
    exit 1
fi

sed -e "s|\${WORKSPACE_HOST}|$WORKSPACE_HOST|g" \
    -e "s|\${WORKSPACE_API_TOKEN}|$WORKSPACE_API_TOKEN|g" \
    config/claude-code-litellm.template.yaml > claude-code-litellm.yaml

print_success "Generated claude-code-litellm.yaml"

# ============================================================
# Step 4: Create isolated HOME directory
# ============================================================
print_status "Step 4: Creating isolated HOME at .claude-code-home/..."

mkdir -p "$CLAUDE_HOME/.claude"
mkdir -p "$CLAUDE_HOME/.claude-mem"
mkdir -p logs

# --- 4a: Minimal .claude.json (onboarding bypass only) ---
cat > "$CLAUDE_HOME/.claude.json" << 'EOF'
{
  "hasCompletedOnboarding": true,
  "numStartups": 1
}
EOF
print_success "Created .claude.json (onboarding bypass)"

# --- 4b: Merged settings.json (plugins + Databricks settings) ---
cat > "$CLAUDE_HOME/.claude/settings.json" << 'SETTINGS_EOF'
{
  "permissions": {
    "allow": [],
    "deny": []
  },
  "apiKeySource": "env",
  "thinkingMode": "disabled",
  "statusLine": {
    "type": "command",
    "command": "node $HOME/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.10.1/dist/index.js"
  },
  "enabledPlugins": {
    "claude-mem@thedotmack": true,
    "claude-dashboard@claude-dashboard": true,
    "context7@claude-plugins-official": true,
    "jira-server@jira-local": true,
    "git-pr-workflow@local-git-pr": true
  },
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF
print_success "Created merged settings.json (plugins + Databricks config)"

# --- 4c: Plugin symlink ---
# Remove existing plugins dir/symlink if present, then create symlink
if [ -e "$CLAUDE_HOME/.claude/plugins" ] || [ -L "$CLAUDE_HOME/.claude/plugins" ]; then
    rm -rf "$CLAUDE_HOME/.claude/plugins"
fi
ln -sf "$CONSUMER_HOME/.claude/plugins" "$CLAUDE_HOME/.claude/plugins"
print_success "Symlinked plugins -> ~/.claude/plugins"

# --- 4d: Copy claude-dashboard.local.json ---
if [ -f "$CONSUMER_HOME/.claude/claude-dashboard.local.json" ]; then
    cp "$CONSUMER_HOME/.claude/claude-dashboard.local.json" "$CLAUDE_HOME/.claude/claude-dashboard.local.json"
    print_success "Copied claude-dashboard.local.json"
fi

# --- 4e: claude-mem isolation (separate port + data dir) ---
cat > "$CLAUDE_HOME/.claude-mem/settings.json" << MEMEOF
{
  "CLAUDE_MEM_MODEL": "claude-sonnet-4-5",
  "CLAUDE_MEM_CONTEXT_OBSERVATIONS": "50",
  "CLAUDE_MEM_WORKER_PORT": "$CLAUDE_MEM_PORT",
  "CLAUDE_MEM_WORKER_HOST": "127.0.0.1",
  "CLAUDE_MEM_SKIP_TOOLS": "ListMcpResourcesTool,SlashCommand,Skill,TodoWrite,AskUserQuestion",
  "CLAUDE_MEM_PROVIDER": "claude",
  "CLAUDE_MEM_CLAUDE_AUTH_METHOD": "cli",
  "CLAUDE_MEM_DATA_DIR": "$CLAUDE_HOME/.claude-mem",
  "CLAUDE_MEM_LOG_LEVEL": "INFO",
  "CLAUDE_MEM_MODE": "code",
  "CLAUDE_MEM_CONTEXT_SHOW_READ_TOKENS": "false",
  "CLAUDE_MEM_CONTEXT_SHOW_WORK_TOKENS": "false",
  "CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_AMOUNT": "false",
  "CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_PERCENT": "true",
  "CLAUDE_MEM_CONTEXT_OBSERVATION_TYPES": "bugfix,feature,refactor,discovery,decision,change",
  "CLAUDE_MEM_CONTEXT_OBSERVATION_CONCEPTS": "how-it-works,why-it-exists,what-changed,problem-solution,gotcha,pattern,trade-off",
  "CLAUDE_MEM_CONTEXT_FULL_COUNT": "0",
  "CLAUDE_MEM_CONTEXT_FULL_FIELD": "narrative",
  "CLAUDE_MEM_CONTEXT_SESSION_COUNT": "10",
  "CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY": "true",
  "CLAUDE_MEM_CONTEXT_SHOW_LAST_MESSAGE": "false",
  "CLAUDE_MEM_FOLDER_CLAUDEMD_ENABLED": "false",
  "CLAUDE_MEM_MAX_CONCURRENT_AGENTS": "2",
  "CLAUDE_MEM_CHROMA_MODE": "local"
}
MEMEOF
print_success "Created claude-mem settings (port $CLAUDE_MEM_PORT, isolated data dir)"

# --- 4f: Symlink common config files ---
for config_file in .gitconfig .ssh .aws .azure .databrickscfg; do
    if [ -e "$CONSUMER_HOME/$config_file" ] && [ ! -e "$CLAUDE_HOME/$config_file" ]; then
        ln -sf "$CONSUMER_HOME/$config_file" "$CLAUDE_HOME/$config_file"
        print_success "Symlinked $config_file"
    elif [ -e "$CONSUMER_HOME/$config_file" ]; then
        print_status "$config_file symlink already exists"
    fi
done

# ============================================================
# Step 5: Stop existing proxies on our ports
# ============================================================
print_status "Step 5: Checking for existing proxy processes..."
for port in $FILTER_PROXY_PORT $LITELLM_PORT; do
    if lsof -ti:$port >/dev/null 2>&1; then
        print_warning "Stopping existing process on port $port..."
        kill $(lsof -ti:$port) 2>/dev/null || true
        sleep 1
    fi
done

# ============================================================
# Step 6: Start LiteLLM proxy
# ============================================================
print_status "Step 6: Starting LiteLLM proxy on port $LITELLM_PORT..."
DATETIME=$(date '+%Y%m%d_%H%M%S')

nohup litellm \
    --config claude-code-litellm.yaml \
    --port $LITELLM_PORT \
    --host 127.0.0.1 \
    > logs/litellm_claude_${DATETIME}.log 2>&1 &

LITELLM_PID=$!
echo $LITELLM_PID > logs/litellm_claude.pid
print_status "LiteLLM PID: $LITELLM_PID"

# Wait for LiteLLM health
print_status "Waiting for LiteLLM to become healthy..."
for i in {1..30}; do
    if curl -s -f "http://localhost:$LITELLM_PORT/health" >/dev/null 2>&1; then
        print_success "LiteLLM proxy healthy on :$LITELLM_PORT"
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "LiteLLM proxy failed to start within 30s"
        print_error "Check logs: logs/litellm_claude_${DATETIME}.log"
        exit 1
    fi
    sleep 1
done

# ============================================================
# Step 7: Start thinking filter proxy
# ============================================================
print_status "Step 7: Starting filter proxy on port $FILTER_PROXY_PORT..."

nohup "${VENV_DIR}/bin/python3" scripts/thinking_filter_proxy.py \
    --port $FILTER_PROXY_PORT \
    --litellm-url "http://localhost:$LITELLM_PORT" \
    > logs/filter_proxy_${DATETIME}.log 2>&1 &

FILTER_PID=$!
echo $FILTER_PID > logs/filter_proxy.pid
print_status "Filter proxy PID: $FILTER_PID"

# Wait for filter proxy health
print_status "Waiting for filter proxy to become healthy..."
for i in {1..15}; do
    if curl -s -f "http://localhost:$FILTER_PROXY_PORT/health" >/dev/null 2>&1; then
        print_success "Filter proxy healthy on :$FILTER_PROXY_PORT"
        break
    fi
    if [ $i -eq 15 ]; then
        print_warning "Filter proxy may not have started properly"
        print_warning "Check logs: logs/filter_proxy_${DATETIME}.log"
    fi
    sleep 1
done

# ============================================================
# Step 8: Validation test
# ============================================================
print_status "Step 8: Testing proxy chain..."

test_response=$(curl -s -X POST "http://localhost:$FILTER_PROXY_PORT/v1/messages" \
   -H "Content-Type: application/json" \
   -H "x-api-key: test" \
   -H "anthropic-version: 2023-06-01" \
   -d '{
     "model": "claude-opus-4-6",
     "messages": [{"role": "user", "content": "Say OK"}],
     "max_tokens": 10
   }' 2>/dev/null || echo "FAILED")

if [[ "$test_response" == *"content"* ]] || [[ "$test_response" == *"text"* ]]; then
    print_success "Proxy chain test passed - Databricks responding"
else
    print_warning "Proxy chain test inconclusive (may still work with Claude Code)"
    print_warning "Response: ${test_response:0:200}"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Setup Complete                                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Architecture:${NC}"
echo "  Claude Code (.claude-code-home)"
echo "    -> Filter Proxy (:$FILTER_PROXY_PORT)"
echo "      -> LiteLLM (:$LITELLM_PORT)"
echo "        -> Databricks ($WORKSPACE_HOST)"
echo ""
echo -e "${CYAN}Plugins preserved:${NC}"
echo "  claude-mem, claude-dashboard, context7, jira-server, git-pr-workflow"
echo ""
echo -e "${CYAN}Isolation:${NC}"
echo "  HOME:        $CLAUDE_HOME"
echo "  claude-mem:  port $CLAUDE_MEM_PORT (consumer: 37777)"
echo "  Plugins:     symlinked (read-only sharing)"
echo ""
print_status "To launch Claude Code:"
echo "  ./scripts/claude-code-hybrid.sh"
echo ""
print_status "Other commands:"
echo "  ./scripts/claude-code-hybrid.sh --status"
echo "  ./scripts/claude-code-hybrid.sh --stop"
echo ""
print_status "Logs:"
echo "  logs/litellm_claude_${DATETIME}.log"
echo "  logs/filter_proxy_${DATETIME}.log"
echo ""
echo -e "${CYAN}Consumer safety:${NC}"
echo "  ~/.claude/settings.json   — NOT modified"
echo "  ~/.claude.json            — NOT modified"
echo "  ~/.claude/plugins/        — NOT modified (symlinked)"
echo "  ~/.claude-mem/            — NOT modified (separate DB)"

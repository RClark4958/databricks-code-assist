#!/bin/bash

# 🚀 Claude Code + Databricks LLM Setup Script
# This script automates the setup process for Claude Code with Databricks
#
# Architecture:
#   Claude Code -> Filter Proxy (4001) -> LiteLLM (4010) -> Databricks
#
# The filter proxy strips "thinking" blocks which Databricks doesn't support.

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Claude Code + Databricks Setup             ║${NC}"
    echo -e "${CYAN}║   Secure Enterprise LLM Endpoint             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

# Check if correct number of arguments provided
if [ $# -ne 2 ]; then
    print_error "Usage: $0 <WORKSPACE_HOST> <WORKSPACE_API_TOKEN>"
    print_error "Example: $0 your-workspace.cloud.databricks.com dapi-your-token"
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

# Remove protocol prefix and trailing slash from workspace host
WORKSPACE_HOST="${WORKSPACE_HOST#https://}"
WORKSPACE_HOST="${WORKSPACE_HOST#http://}"
WORKSPACE_HOST="${WORKSPACE_HOST%/}"

print_header
print_status "Workspace Host: $WORKSPACE_HOST"
print_status "API Token: ${WORKSPACE_API_TOKEN:0:10}..."
echo ""

# Change to the project directory
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# Ports configuration
FILTER_PROXY_PORT=4001
LITELLM_PORT=4010

# Claude Code isolated home directory
CLAUDE_HOME="${PROJECT_ROOT}/.claude-code-home"

# Step 1: Verify Databricks connection
print_status "Step 1: Verifying Databricks connection..."
response=$(curl -s -w "%{http_code}" -X GET "https://$WORKSPACE_HOST/api/2.0/serving-endpoints" \
  -H "Authorization: Bearer $WORKSPACE_API_TOKEN" \
  -o /tmp/databricks_test.json)

if [ "$response" != "200" ]; then
    print_error "Failed to connect to Databricks workspace. HTTP status: $response"
    print_error "Please check your WORKSPACE_HOST and WORKSPACE_API_TOKEN"
    exit 1
fi

print_success "Successfully connected to Databricks workspace"

# Step 2: Check/Install Claude Code CLI
print_status "Step 2: Checking Claude Code installation..."
if ! command -v claude &> /dev/null; then
    print_status "Installing Claude Code CLI..."

    # Check if npm is available
    if ! command -v npm &> /dev/null; then
        print_error "npm is not installed. Please install Node.js first."
        print_error "Visit: https://nodejs.org/ or run: brew install node"
        exit 1
    fi

    npm install -g @anthropic-ai/claude-code

    # Verify installation
    if ! command -v claude &> /dev/null; then
        print_error "Claude Code installation failed. Please install manually."
        exit 1
    fi
    print_success "Claude Code installed successfully"
else
    print_success "Claude Code is already installed"
    claude_version=$(claude --version 2>&1 | head -1 || echo "unknown")
    print_status "Claude Code version: $claude_version"
fi

# Step 3: Install LiteLLM if not already installed
print_status "Step 3: Checking LiteLLM installation..."
if ! command -v litellm &> /dev/null; then
    print_status "Installing LiteLLM..."
    pip install 'litellm[proxy]' --upgrade
    print_success "LiteLLM installed successfully"
else
    print_success "LiteLLM is already installed"
fi

# Step 4: Install filter proxy dependencies
print_status "Step 4: Installing filter proxy dependencies..."
if ! python3 -c "import fastapi, httpx, uvicorn" 2>/dev/null; then
    pip install fastapi httpx uvicorn --upgrade
    print_success "Filter proxy dependencies installed"
else
    print_success "Filter proxy dependencies already installed"
fi

# Step 5: Create LiteLLM config from template
print_status "Step 5: Creating LiteLLM configuration..."
if [ ! -f "config/claude-code-litellm.template.yaml" ]; then
    print_error "Template file config/claude-code-litellm.template.yaml not found"
    exit 1
fi

sed -e "s|\${WORKSPACE_HOST}|$WORKSPACE_HOST|g" \
    -e "s|\${WORKSPACE_API_TOKEN}|$WORKSPACE_API_TOKEN|g" \
    config/claude-code-litellm.template.yaml > claude-code-litellm.yaml

print_success "LiteLLM configuration created"

# Step 6: Create logs directory
mkdir -p logs

# Step 7: Stop any existing proxies on our ports
print_status "Step 6: Checking for existing proxy processes..."
for port in $FILTER_PROXY_PORT $LITELLM_PORT; do
    if lsof -ti:$port >/dev/null 2>&1; then
        print_warning "Stopping existing process on port $port..."
        kill $(lsof -ti:$port) 2>/dev/null || true
        sleep 1
    fi
done

# Step 8: Start LiteLLM proxy
print_status "Step 7: Starting LiteLLM proxy on port $LITELLM_PORT..."
DATETIME=$(date '+%Y%m%d_%H%M%S')

nohup litellm \
    --config claude-code-litellm.yaml \
    --port $LITELLM_PORT \
    --host 127.0.0.1 \
    > logs/litellm_claude_${DATETIME}.log 2>&1 &

LITELLM_PID=$!
echo $LITELLM_PID > logs/litellm_claude.pid
print_success "LiteLLM proxy started (PID: $LITELLM_PID)"

# Wait for LiteLLM to be ready
print_status "Waiting for LiteLLM to start..."
for i in {1..30}; do
    if curl -s -f "http://localhost:$LITELLM_PORT/health" >/dev/null 2>&1; then
        print_success "LiteLLM proxy is running and healthy"
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "LiteLLM proxy failed to start"
        print_error "Check logs at: logs/litellm_claude_${DATETIME}.log"
        exit 1
    fi
    sleep 1
done

# Step 9: Start thinking filter proxy
print_status "Step 8: Starting thinking filter proxy on port $FILTER_PROXY_PORT..."

nohup python3 scripts/thinking_filter_proxy.py \
    --port $FILTER_PROXY_PORT \
    --litellm-url "http://localhost:$LITELLM_PORT" \
    > logs/filter_proxy_${DATETIME}.log 2>&1 &

FILTER_PID=$!
echo $FILTER_PID > logs/filter_proxy.pid
print_success "Filter proxy started (PID: $FILTER_PID)"

# Wait for filter proxy to be ready
print_status "Waiting for filter proxy to start..."
for i in {1..15}; do
    if curl -s -f "http://localhost:$FILTER_PROXY_PORT/health" >/dev/null 2>&1; then
        print_success "Filter proxy is running and healthy"
        break
    fi
    if [ $i -eq 15 ]; then
        print_warning "Filter proxy may not have started properly"
        print_warning "Check logs at: logs/filter_proxy_${DATETIME}.log"
    fi
    sleep 1
done

# Step 10: Create Claude Code isolated environment
print_status "Step 9: Setting up Claude Code environment..."
mkdir -p "$CLAUDE_HOME"
mkdir -p "$CLAUDE_HOME/.claude"

# Create .claude.json to bypass Anthropic login
cat > "$CLAUDE_HOME/.claude.json" << 'EOF'
{
  "hasCompletedOnboarding": true,
  "numStartups": 1
}
EOF

# Create settings.json
cat > "$CLAUDE_HOME/.claude/settings.json" << EOF
{
  "permissions": {
    "allow": [],
    "deny": []
  },
  "apiKeySource": "env",
  "thinkingMode": "disabled"
}
EOF

print_success "Claude Code environment configured"

# Step 11: Create the wrapper script
print_status "Step 10: Creating Claude Code wrapper script..."
cat > scripts/claude-code.sh << 'WRAPPER_EOF'
#!/bin/bash
# Claude Code wrapper for Databricks integration
# This script launches Claude Code connected to Databricks via the proxy stack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Ports
FILTER_PROXY_PORT=4001
LITELLM_PORT=4010

# Claude Code isolated home
CLAUDE_HOME="${PROJECT_ROOT}/.claude-code-home"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Check if proxies are running
check_proxy() {
    if ! curl -s "http://localhost:$FILTER_PROXY_PORT/health" 2>/dev/null | grep -q "healthy"; then
        echo -e "${YELLOW}Proxy not running. Please run setup_claude_code.sh first.${NC}"
        echo -e "  ./scripts/setup_claude_code.sh <WORKSPACE_HOST> <WORKSPACE_API_TOKEN>"
        exit 1
    fi
}

# Handle special commands
case "${1:-}" in
    --status)
        echo -e "${CYAN}Proxy Status:${NC}"
        if curl -s "http://localhost:$FILTER_PROXY_PORT/health" 2>/dev/null | grep -q "healthy"; then
            echo -e "  Filter Proxy (port $FILTER_PROXY_PORT): ${GREEN}Running${NC}"
        else
            echo -e "  Filter Proxy (port $FILTER_PROXY_PORT): ${RED}Not running${NC}"
        fi
        if curl -s "http://localhost:$LITELLM_PORT/health" 2>/dev/null | grep -q "healthy"; then
            echo -e "  LiteLLM (port $LITELLM_PORT): ${GREEN}Running${NC}"
        else
            echo -e "  LiteLLM (port $LITELLM_PORT): ${RED}Not running${NC}"
        fi
        exit 0
        ;;
    --stop)
        echo "Stopping proxies..."
        [ -f "$PROJECT_ROOT/logs/filter_proxy.pid" ] && kill $(cat "$PROJECT_ROOT/logs/filter_proxy.pid") 2>/dev/null
        [ -f "$PROJECT_ROOT/logs/litellm_claude.pid" ] && kill $(cat "$PROJECT_ROOT/logs/litellm_claude.pid") 2>/dev/null
        rm -f "$PROJECT_ROOT/logs/filter_proxy.pid" "$PROJECT_ROOT/logs/litellm_claude.pid"
        echo "Proxies stopped."
        exit 0
        ;;
    --help|-h)
        echo "Claude Code via Databricks"
        echo ""
        echo "Usage: claude-code.sh [OPTIONS] [CLAUDE_ARGS...]"
        echo ""
        echo "Options:"
        echo "  --status     Check proxy status"
        echo "  --stop       Stop the proxy servers"
        echo "  --help, -h   Show this help"
        echo ""
        echo "All other arguments are passed to Claude Code."
        exit 0
        ;;
esac

check_proxy

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Claude Code via Databricks                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓${NC} Proxy running on port $FILTER_PROXY_PORT"
echo ""

# Save original HOME for tools that need it
ORIGINAL_HOME="$HOME"

# Override HOME for Claude Code isolation
export HOME="$CLAUDE_HOME"

# Point to Databricks proxy
export ANTHROPIC_BASE_URL="http://localhost:$FILTER_PROXY_PORT"
export ANTHROPIC_API_KEY="databricks-via-litellm"

# Preserve access to common config files
export DATABRICKS_CONFIG_FILE="$ORIGINAL_HOME/.databrickscfg"
for config_file in .gitconfig .ssh .aws .azure .npmrc .pypirc; do
    if [ -e "$ORIGINAL_HOME/$config_file" ] && [ ! -e "$CLAUDE_HOME/$config_file" ]; then
        ln -sf "$ORIGINAL_HOME/$config_file" "$CLAUDE_HOME/$config_file"
    fi
done

# Unset conflicting auth tokens
unset ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true

# Launch Claude Code
exec claude "$@"
WRAPPER_EOF

chmod +x scripts/claude-code.sh
print_success "Wrapper script created"

# Step 12: Test the proxy
print_status "Step 11: Testing proxy connection..."
test_response=$(curl -s -X POST "http://localhost:$FILTER_PROXY_PORT/v1/messages" \
   -H "Content-Type: application/json" \
   -H "x-api-key: test" \
   -H "anthropic-version: 2023-06-01" \
   -d '{
     "model": "claude-sonnet-4-5-20250929",
     "messages": [{"role": "user", "content": "Say OK"}],
     "max_tokens": 10
   }' 2>/dev/null || echo "FAILED")

if [[ "$test_response" == *"content"* ]] || [[ "$test_response" == *"text"* ]]; then
    print_success "Proxy test successful - Databricks connection working"
else
    print_warning "Proxy test may have failed, but setup is complete"
    print_warning "Check logs in the logs/ directory"
fi

# Final instructions
echo ""
print_success "🎉 Setup completed successfully!"
echo ""
echo -e "${CYAN}Architecture:${NC}"
echo "  Claude Code -> Filter Proxy (:$FILTER_PROXY_PORT) -> LiteLLM (:$LITELLM_PORT) -> Databricks"
echo ""
print_status "To run Claude Code:"
echo "  ./scripts/claude-code.sh"
echo ""
print_status "Other commands:"
echo "  ./scripts/claude-code.sh --status    # Check proxy status"
echo "  ./scripts/claude-code.sh --stop      # Stop proxies"
echo "  ./scripts/claude-code.sh -p 'Hello'  # One-off prompt"
echo ""
print_status "Logs:"
echo "  logs/litellm_claude_${DATETIME}.log"
echo "  logs/filter_proxy_${DATETIME}.log"
echo ""
print_status "Configuration:"
echo "  LiteLLM: claude-code-litellm.yaml"
echo "  Claude:  .claude-code-home/.claude/settings.json"
echo ""
print_success "No Anthropic account required - all requests go through Databricks! 🔒"

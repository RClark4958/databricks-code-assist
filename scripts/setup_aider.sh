#!/bin/bash

# 🚀 Aider + Databricks LLM Setup Script
# This script automates the setup process for Aider with Databricks

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Check if correct number of arguments provided
if [ $# -ne 2 ]; then
    print_error "Usage: $0 <WORKSPACE_HOST> <WORKSPACE_API_TOKEN>"
    print_error "Example: $0 https://your-workspace.cloud.databricks.com dapi-your-token"
    exit 1
fi

WORKSPACE_HOST="$1"
WORKSPACE_API_TOKEN="$2"

# Remove trailing slash from workspace host if present
WORKSPACE_HOST="${WORKSPACE_HOST%/}"

print_status "Starting Aider + Databricks LLM setup..."
print_status "Workspace Host: $WORKSPACE_HOST"
print_status "API Token: ${WORKSPACE_API_TOKEN:0:10}..."

# Change to the project directory
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

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

# Step 2: Check/Install Aider
print_status "Step 2: Checking Aider installation..."
if ! command -v aider &> /dev/null; then
    print_status "Installing Aider..."
    curl -LsSf https://aider.chat/install.sh | sh

    # Verify installation
    if ! command -v aider &> /dev/null; then
        print_error "Aider installation failed. Please install manually."
        exit 1
    fi
    print_success "Aider installed successfully"
else
    print_success "Aider is already installed"
    aider_version=$(aider --version 2>&1 || echo "unknown")
    print_status "Aider version: $aider_version"
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

# Step 4: Create LiteLLM config from template
print_status "Step 4: Creating LiteLLM configuration..."
if [ ! -f "config/litellm_config.template.yaml" ]; then
    print_error "Template file config/litellm_config.template.yaml not found"
    exit 1
fi

sed -e "s|\${WORKSPACE_HOST}|$WORKSPACE_HOST|g" \
    -e "s|\${WORKSPACE_API_TOKEN}|$WORKSPACE_API_TOKEN|g" \
    config/litellm_config.template.yaml > litellm_config.yaml

print_success "LiteLLM configuration created"

# Step 5: Create logs directory if it doesn't exist
mkdir -p logs

# Step 6: Start or verify LiteLLM proxy
print_status "Step 5: Checking LiteLLM proxy status..."
LITELLM_PID=""
DATETIME=$(date '+%Y%m%d_%H%M%S')

# Check if LiteLLM is already running on port 4000
if lsof -ti:4000 >/dev/null 2>&1; then
    # Verify it's healthy
    if curl -s -f "http://localhost:4000/health" >/dev/null 2>&1; then
        LITELLM_PID=$(lsof -ti:4000)
        print_success "LiteLLM proxy is already running (PID: $LITELLM_PID)"
    else
        print_warning "Port 4000 is in use but LiteLLM is not responding. Restarting..."
        kill $(lsof -ti:4000) 2>/dev/null || true
        sleep 2
        nohup litellm --config litellm_config.yaml --port 4000 > logs/litellm_${DATETIME}.log 2>&1 &
        LITELLM_PID=$!
        print_success "LiteLLM proxy restarted with PID: $LITELLM_PID"
        print_status "Logs are being written to: logs/litellm_${DATETIME}.log"
    fi
else
    # Start LiteLLM proxy
    print_status "Starting LiteLLM proxy..."
    nohup litellm --config litellm_config.yaml --port 4000 > logs/litellm_${DATETIME}.log 2>&1 &
    LITELLM_PID=$!
    print_success "LiteLLM proxy started with PID: $LITELLM_PID"
    print_status "Logs are being written to: logs/litellm_${DATETIME}.log"
fi

# Step 7: Wait for LiteLLM to be ready (if just started)
if [ -n "$DATETIME" ]; then
    print_status "Step 6: Waiting for LiteLLM proxy to start up..."
    sleep 5

    # Test LiteLLM connection
    for i in {1..10}; do
        if curl -s -f "http://localhost:4000/health" >/dev/null 2>&1; then
            print_success "LiteLLM proxy is running and healthy"
            break
        fi
        if [ $i -eq 10 ]; then
            print_error "LiteLLM proxy failed to start properly"
            print_error "Check the logs at: logs/litellm_${DATETIME}.log"
            exit 1
        fi
        print_status "Waiting for LiteLLM to be ready... (attempt $i/10)"
        sleep 2
    done
fi

# Step 8: Test LiteLLM with a simple request
print_status "Step 7: Testing LiteLLM proxy..."
test_response=$(curl -s -X POST "http://localhost:4000/v1/chat/completions" \
   -H "Content-Type: application/json" \
   -d '{
     "model": "claude-sonnet-4",
     "messages": [
       {"role": "user", "content": "Hello, respond with just OK"}
     ],
     "max_tokens": 10
   }' 2>/dev/null || echo "FAILED")

if [[ "$test_response" == *"OK"* ]] || [[ "$test_response" == *"content"* ]]; then
    print_success "LiteLLM proxy test successful"
else
    print_warning "LiteLLM proxy test may have failed, but continuing..."
    print_warning "You can check the logs at: logs/litellm_${DATETIME}.log"
fi

# Step 9: Create Aider configuration
print_status "Step 8: Creating Aider configuration..."

# Create .aider.conf.yml in project root
cat > "${PROJECT_ROOT}/.aider.conf.yml" << EOF
# Aider configuration for Databricks LLM integration
# Generated by setup_aider.sh

# Use OpenAI-compatible API endpoint (LiteLLM proxy)
openai-api-base: http://localhost:4000/v1

# Set the model to use
model: claude-sonnet-4

# API key (can be any non-empty string for local proxy)
openai-api-key: not-needed

# Git settings
auto-commits: true
dirty-commits: true

# Editor settings
editor: auto

# Other settings
pretty: true
stream: true
EOF

print_success "Aider configuration created at ${PROJECT_ROOT}/.aider.conf.yml"

# Step 10: Test Aider connection
print_status "Step 9: Testing Aider connection..."
test_output=$(aider --model claude-sonnet-4 --message "Hello, respond with just 'OK'" --no-auto-commits --yes 2>&1 || echo "FAILED")

if [[ "$test_output" == *"OK"* ]] || [[ "$test_output" == *"successfully"* ]]; then
    print_success "Aider connection test successful"
else
    print_warning "Aider connection test may have failed, but configuration is in place"
    print_warning "You can test manually by running: aider --message 'Hello'"
fi

# Final instructions
echo ""
print_success "🎉 Setup completed successfully!"
echo ""
print_status "Next steps:"
echo "  1. Navigate to your project directory: cd ${PROJECT_ROOT}"
echo "  2. Start Aider by running: aider"
echo "  3. Or use Aider with specific files: aider file1.py file2.py"
echo "  4. Or use Aider in read-only mode: aider --read file1.py --edit file2.py"
echo ""
print_status "Quick Aider commands:"
echo "  • Chat with your code: aider"
echo "  • One-off command: aider --message 'your request here'"
echo "  • Add files: /add filename.py (inside Aider session)"
echo "  • Drop files: /drop filename.py (inside Aider session)"
echo "  • Help: /help (inside Aider session)"
echo ""
print_status "LiteLLM proxy is running on port 4000"
if [ -n "$LITELLM_PID" ]; then
    print_status "LiteLLM proxy PID: $LITELLM_PID"
fi
if [ -n "$DATETIME" ]; then
    print_status "Logs: logs/litellm_${DATETIME}.log"
fi
echo ""
print_status "Configuration files:"
echo "  • Aider config: ${PROJECT_ROOT}/.aider.conf.yml"
echo "  • LiteLLM config: ${PROJECT_ROOT}/litellm_config.yaml"
echo ""
print_status "To check if the proxy is still running:"
echo "  curl http://localhost:4000/health"
echo ""
if [ -n "$LITELLM_PID" ]; then
    print_status "To stop the proxy later, run: kill $LITELLM_PID"
fi
echo ""
print_success "Happy coding with Aider + Databricks! 🚀"

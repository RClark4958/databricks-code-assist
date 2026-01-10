# 🚀 Databricks LLM AI Coding Assistants Setup Guide

Quick setup for using AI coding assistants (Continue.dev or Aider) powered by Databricks LLMs via LiteLLM.

## 📺 Demo

![Demo GIF](./img/CodeAssistDABContinuous.gif)

## Prerequisites

- 🔧 Databricks workspace with Foundation Model APIs access
- 🐍 Python 3.8+ with pip
- 💻 VS Code (for Continue.dev) or Terminal (for Aider)

## 🔑 Databricks Setup

### Generate Access Token
```
Workspace Settings → Advanced → Personal Access Tokens → Generate New Token
```

### Store Credentials
```bash
export WORKSPACE_HOST=adb-1234567890.10.azuredatabricks.net
export WORKSPACE_API_TOKEN=dapi-your-token
```

### Verify Connection
```bash
curl -X GET "https://$WORKSPACE_HOST/api/2.0/serving-endpoints" \
  -H "Authorization: Bearer $WORKSPACE_API_TOKEN"
```

## 🔧 LiteLLM Setup

### Install and Start
```bash
pip install 'litellm[proxy]' --upgrade

# Create config
sed -e "s/\${WORKSPACE_HOST}/$WORKSPACE_HOST/g" \
    -e "s/\${WORKSPACE_API_TOKEN}/$WORKSPACE_API_TOKEN/g" \
    config/litellm_config.template.yaml > litellm_config.yaml

# Start proxy
DATETIME=$(date '+%Y%m%d_%H%M%S')
mkdir -p logs
nohup litellm --config litellm_config.yaml --port 4000 > logs/litellm_${DATETIME}.log 2>&1 &
```

### Test
```bash
curl http://localhost:4000/health
```

## 🅰️ Continue.dev Setup

### Install Extension
```bash
code --install-extension Continue.continue
```

### Quick Setup Script
```bash
chmod +x ./scripts/run.sh
./scripts/run.sh $WORKSPACE_HOST $WORKSPACE_API_TOKEN
```

### Start Using
1. Open VS Code
2. Press `CMD/CTRL + I` to open Continue panel
3. Select model and start coding

## 🅱️ Aider Setup

### Install Aider
```bash
curl -LsSf https://aider.chat/install.sh | sh
```

### Quick Setup Script
```bash
chmod +x ./scripts/setup_aider.sh
./scripts/setup_aider.sh $WORKSPACE_HOST $WORKSPACE_API_TOKEN
```

### Start Using
```bash
# Navigate to your project
cd /path/to/project

# Start Aider
aider --model openai/claude-sonnet-4
```

## 🎉 That's It!

Both tools use the same LiteLLM proxy. Choose the one that fits your workflow:
- **Continue.dev**: GUI in VS Code
- **Aider**: Terminal CLI

Keep the LiteLLM proxy running while using either tool.

# Databricks Code Assist

Quick setup for using AI coding assistants (Continue.dev, Aider, or Claude Code) powered by Databricks LLMs via LiteLLM.

![Demo](./img/CodeAssistDABContinuous.gif)

## Installation

```bash
pip install -e .
```

## Quick Start

### 1. Setup

```bash
databricks-code-assist setup
```

This will prompt for your Databricks workspace host and API token, then configure everything automatically.

### 2. Validate

```bash
databricks-code-assist validate
```

Tests the connection to Databricks and the LiteLLM proxy.

### 3. Run

**Start Aider (terminal-based coding assistant):**

```bash
databricks-code-assist run aider
```

**Start Continue.dev (VS Code extension):**

```bash
databricks-code-assist run continue
```

Then open VS Code and press `Cmd/Ctrl+I` to use Continue.

## Commands

| Command | Description |
|---------|-------------|
| `databricks-code-assist setup` | Configure Databricks credentials |
| `databricks-code-assist validate` | Test the connection |
| `databricks-code-assist run aider` | Start Aider with Databricks LLM |
| `databricks-code-assist run continue` | Start Continue.dev with Databricks LLM |
| `databricks-code-assist status` | Show current configuration |
| `databricks-code-assist stop` | Stop the LiteLLM proxy |

## Options

All commands support these options:

```bash
--port PORT    # LiteLLM proxy port (default: 4000)
--help         # Show help
```

Setup command options:

```bash
--host HOST        # Databricks workspace URL
--api-key KEY      # Databricks API token
--model MODEL      # Model name (default: claude-sonnet-4)
```

## Examples

### Using Aider with specific files

```bash
databricks-code-assist run aider -- file1.py file2.py
```

### Using Aider in read-only mode

```bash
databricks-code-assist run aider -- --read myfile.py
```

### Custom port

```bash
databricks-code-assist setup --port 5000
databricks-code-assist run aider --port 5000
```

## Claude Code Setup

Claude Code is Anthropic's official CLI for Claude, offering advanced agentic coding capabilities.

> **Note:** Claude Code requires a separate proxy stack (ports 4001 + 4010) because it uses the Anthropic API format instead of OpenAI format. No Anthropic account is required.

### Prerequisites
- Node.js 18+ (`brew install node` or [nodejs.org](https://nodejs.org))
- Python 3.13 (`brew install python@3.13`)

### Quick Setup
```bash
# Create venv and install dependencies
python3.13 -m venv .venv
source .venv/bin/activate
pip install httpx fastapi uvicorn 'litellm[proxy]'

# Run setup (starts proxies and creates isolated environment)
./scripts/setup_claude_code_hybrid.sh <WORKSPACE_HOST> <WORKSPACE_API_TOKEN>
```

### Start Using
```bash
# Launch Claude Code via Databricks
./scripts/claude-code-hybrid.sh

# Check proxy status
./scripts/claude-code-hybrid.sh --status

# Stop proxies when done
./scripts/claude-code-hybrid.sh --stop
```

### Architecture
```
Claude Code -> Filter Proxy (:4001) -> LiteLLM (:4010) -> Databricks
```

The filter proxy strips "thinking" blocks and ensures tool message compatibility with Databricks endpoints.

### Configuration
Claude Code configuration is stored in `.claude-code-home/` within this project directory, not in `~/.claude/`. This keeps the Databricks instance fully isolated from any consumer Claude Code installation.

## Configuration

Configuration is stored in `~/.databricks-code-assist/`:

- `config.yaml` - Databricks credentials and settings
- `litellm_config.yaml` - LiteLLM proxy configuration
- `logs/` - LiteLLM proxy logs

## Environment Variables

You can also set credentials via environment variables:

```bash
export DATABRICKS_HOST=your-workspace.cloud.databricks.com
export DATABRICKS_TOKEN=dapi-your-token
```

## Requirements

- Python 3.9+ (Python 3.13 for Claude Code)
- Databricks workspace with Foundation Model APIs access
- VS Code (for Continue.dev)
- Node.js 18+ (for Claude Code)

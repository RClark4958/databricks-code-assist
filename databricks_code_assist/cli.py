"""CLI commands for Databricks Code Assist."""

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import click
import requests
from rich.console import Console
from rich.panel import Panel

from . import __version__
from .config import (
    CONFIG_DIR,
    DEFAULT_MODEL,
    DEFAULT_PORT,
    LITELLM_CONFIG_FILE,
    LOGS_DIR,
    generate_aider_config,
    generate_continue_config,
    generate_litellm_config,
    get_config,
    get_databricks_credentials,
    save_config,
)

console = Console()


def print_status(message: str) -> None:
    """Print an info message."""
    console.print(f"[blue][INFO][/blue] {message}")


def print_success(message: str) -> None:
    """Print a success message."""
    console.print(f"[green][SUCCESS][/green] {message}")


def print_warning(message: str) -> None:
    """Print a warning message."""
    console.print(f"[yellow][WARNING][/yellow] {message}")


def print_error(message: str) -> None:
    """Print an error message."""
    console.print(f"[red][ERROR][/red] {message}")


def verify_databricks_connection(host: str, api_key: str) -> bool:
    """Verify connection to Databricks workspace.

    Args:
        host: Databricks workspace host
        api_key: Databricks API token

    Returns:
        True if connection successful, False otherwise
    """
    try:
        response = requests.get(
            f"https://{host}/api/2.0/serving-endpoints",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=30,
        )
        return response.status_code == 200
    except requests.RequestException:
        return False


def get_available_models(host: str, api_key: str) -> list[dict]:
    """Fetch available serving endpoints from Databricks workspace.

    Args:
        host: Databricks workspace host
        api_key: Databricks API token

    Returns:
        List of available model endpoints with name and type
    """
    try:
        response = requests.get(
            f"https://{host}/api/2.0/serving-endpoints",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=30,
        )
        if response.status_code != 200:
            return []

        data = response.json()
        endpoints = data.get("endpoints", [])

        models = []
        for endpoint in endpoints:
            name = endpoint.get("name", "")
            state = endpoint.get("state", {}).get("ready", "")
            endpoint_type = endpoint.get("endpoint_type", "unknown")

            # Only include ready endpoints
            if state == "READY":
                models.append({
                    "name": name,
                    "type": endpoint_type,
                    "display": f"{name} ({endpoint_type})",
                })

        # Sort by name, prioritizing foundation models
        models.sort(key=lambda x: (0 if "FOUNDATION" in x["type"] else 1, x["name"]))

        return models
    except requests.RequestException:
        return []


def check_litellm_installed() -> bool:
    """Check if LiteLLM is installed."""
    try:
        subprocess.run(
            ["litellm", "--version"],
            capture_output=True,
            check=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def check_aider_installed() -> bool:
    """Check if Aider is installed."""
    try:
        subprocess.run(
            ["aider", "--version"],
            capture_output=True,
            check=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def start_litellm_proxy(port: int = DEFAULT_PORT) -> subprocess.Popen | None:
    """Start the LiteLLM proxy server.

    Args:
        port: Port to run the proxy on

    Returns:
        Popen object for the proxy process, or None if failed
    """
    if not LITELLM_CONFIG_FILE.exists():
        print_error("LiteLLM configuration not found. Run 'databricks-code-assist setup' first.")
        return None

    # Check if port is already in use
    try:
        response = requests.get(f"http://localhost:{port}/health", timeout=2)
        if response.ok:
            print_success(f"LiteLLM proxy already running on port {port}")
            return None  # Return None to indicate it's already running
    except requests.RequestException:
        pass  # Port not in use, we can start the proxy

    # Create log file
    log_file = LOGS_DIR / f"litellm_{time.strftime('%Y%m%d_%H%M%S')}.log"

    with open(log_file, "w") as log:
        proxy = subprocess.Popen(
            ["litellm", "--config", str(LITELLM_CONFIG_FILE), "--port", str(port)],
            stdout=log,
            stderr=log,
            preexec_fn=os.setsid if os.name != "nt" else None,
        )

    print_status(f"Starting LiteLLM proxy (PID: {proxy.pid})...")
    print_status(f"Logs: {log_file}")

    # Wait for proxy to be ready
    for i in range(30):
        try:
            response = requests.get(f"http://localhost:{port}/health", timeout=2)
            if response.ok:
                print_success(f"LiteLLM proxy started on port {port}")
                return proxy
        except requests.RequestException:
            pass
        time.sleep(1)

    print_error("LiteLLM proxy failed to start. Check the logs.")
    proxy.terminate()
    return None


def stop_litellm_proxy(port: int = DEFAULT_PORT) -> None:
    """Stop the LiteLLM proxy server on the given port."""
    if os.name == "nt":
        # Windows
        subprocess.run(
            ["taskkill", "/F", "/IM", "litellm.exe"],
            capture_output=True,
        )
    else:
        # Unix-like
        try:
            result = subprocess.run(
                ["lsof", "-ti", f":{port}"],
                capture_output=True,
                text=True,
            )
            if result.stdout.strip():
                pids = result.stdout.strip().split("\n")
                for pid in pids:
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except (ProcessLookupError, ValueError):
                        pass
                print_success(f"Stopped LiteLLM proxy on port {port}")
        except Exception:
            pass


@click.group()
@click.version_option(version=__version__)
def main():
    """Databricks Code Assist - Setup AI coding assistants with Databricks LLMs."""
    pass


@main.command()
@click.option("--host", default=None, help="Databricks workspace URL (without https://)")
@click.option("--api-key", default=None, help="Databricks personal access token")
@click.option("--model", default=None, help="Model to use (will prompt with available models if not specified)")
@click.option("--port", default=None, type=int, help=f"LiteLLM proxy port (default: {DEFAULT_PORT})")
def setup(host: str | None, api_key: str | None, model: str | None, port: int | None):
    """Configure Databricks credentials and generate configuration files.

    Examples:

        databricks-code-assist setup

        databricks-code-assist setup --host adb-123.10.azuredatabricks.net --api-key dapi...

    When re-running setup, previous values are used as defaults. Just press Enter to keep them.
    """
    # Load existing config for defaults
    existing_config = get_config()
    existing_host = existing_config.get("host", "")
    existing_api_key = existing_config.get("api_key", "")
    existing_model = existing_config.get("model", DEFAULT_MODEL)
    existing_port = existing_config.get("port", DEFAULT_PORT)

    console.print(Panel(
        "[bold]Setting up Databricks Code Assist[/bold]\n\n"
        "This will configure your Databricks credentials and set up the LiteLLM proxy.\n\n"
        "[dim]Tip: Get your API token from Workspace Settings → Developer → Access Tokens[/dim]\n"
        "[dim]Press Enter to keep existing values.[/dim]" if existing_host else "",
        style="blue",
    ))

    # Prompt for host if not provided
    if host is None:
        default_display = f" [{existing_host}]" if existing_host else ""
        host_prompt = f"Databricks workspace host (e.g., adb-123.azuredatabricks.net){default_display}"
        host = click.prompt(host_prompt, default=existing_host if existing_host else None, show_default=False)

    # Prompt for API key if not provided
    if api_key is None:
        if existing_api_key:
            masked_key = existing_api_key[:8] + "..." + existing_api_key[-4:] if len(existing_api_key) > 12 else "****"
            api_key_prompt = f"Databricks API token (starts with 'dapi') [{masked_key}]"
            api_key_input = click.prompt(api_key_prompt, default="", hide_input=True, show_default=False)
            api_key = api_key_input if api_key_input else existing_api_key
        else:
            api_key = click.prompt("Databricks API token (starts with 'dapi')", hide_input=True)

    # Use existing port if not provided
    if port is None:
        port = existing_port

    # Clean up host
    host = host.replace("https://", "").replace("http://", "").rstrip("/")

    # Validate inputs
    if not host or host == "":
        print_error("Host cannot be empty.")
        print_status("Example: adb-1234567890.10.azuredatabricks.net")
        sys.exit(1)

    if not api_key or api_key == "":
        print_error("API token cannot be empty.")
        sys.exit(1)

    if not api_key.startswith("dapi"):
        print_warning("API token doesn't start with 'dapi'. Make sure you're using a Databricks personal access token.")

    # Verify connection
    print_status("Verifying Databricks connection...")
    if not verify_databricks_connection(host, api_key):
        print_error("Failed to connect to Databricks workspace.")
        print_error("Please check your host and API token.")
        sys.exit(1)
    print_success("Successfully connected to Databricks workspace")

    # Fetch available models if not specified
    if model is None:
        print_status("Fetching available models...")
        available_models = get_available_models(host, api_key)

        if not available_models:
            print_warning("No serving endpoints found. Using default model.")
            model = existing_model
        else:
            console.print("\n[bold]Available models:[/bold]")

            # Find index of existing model if it's in the list
            default_idx = 1
            for i, m in enumerate(available_models, 1):
                is_current = m["name"] == existing_model
                marker = " [current]" if is_current else ""
                console.print(f"  {i}. {m['display']}{marker}")
                if is_current:
                    default_idx = i

            console.print()
            while True:
                choice = click.prompt(
                    "Select a model (enter number or name)",
                    default=str(default_idx),
                )

                # Try to parse as number
                try:
                    idx = int(choice) - 1
                    if 0 <= idx < len(available_models):
                        model = available_models[idx]["name"]
                        break
                    else:
                        print_error(f"Please enter a number between 1 and {len(available_models)}")
                except ValueError:
                    # Try to match by name
                    matching = [m for m in available_models if choice.lower() in m["name"].lower()]
                    if len(matching) == 1:
                        model = matching[0]["name"]
                        break
                    elif len(matching) > 1:
                        print_error(f"Multiple models match '{choice}'. Please be more specific.")
                    else:
                        print_error(f"No model found matching '{choice}'")

            print_success(f"Selected model: {model}")

    # Check LiteLLM installation
    print_status("Checking LiteLLM installation...")
    if not check_litellm_installed():
        print_warning("LiteLLM not installed. Installing...")
        subprocess.run([sys.executable, "-m", "pip", "install", "litellm[proxy]"], check=True)
        print_success("LiteLLM installed")
    else:
        print_success("LiteLLM is installed")

    # Save configuration
    print_status("Saving configuration...")
    save_config({
        "host": host,
        "api_key": api_key,
        "model": model,
        "port": port,
    })
    print_success(f"Configuration saved to {CONFIG_DIR}/config.yaml")

    # Generate LiteLLM config
    print_status("Generating LiteLLM configuration...")
    generate_litellm_config(host, api_key, model)
    print_success(f"LiteLLM config saved to {LITELLM_CONFIG_FILE}")

    console.print()
    console.print(Panel(
        "[green]Setup complete![/green]\n\n"
        "Next steps:\n"
        "  1. Run 'databricks-code-assist validate' to test the connection\n"
        "  2. Run 'databricks-code-assist run aider' to start Aider\n"
        "  3. Run 'databricks-code-assist run continue' to setup Continue.dev",
        title="Success",
        style="green",
    ))


@main.command()
@click.option("--port", default=None, type=int, help="LiteLLM proxy port")
def validate(port: int | None):
    """Validate the setup by testing the LiteLLM proxy connection."""
    console.print(Panel("Validating Databricks Code Assist Setup", style="blue"))

    host, api_key = get_databricks_credentials()
    if not host or not api_key:
        print_error("Credentials not found. Run 'databricks-code-assist setup' first.")
        sys.exit(1)

    config = get_config()
    port = port or config.get("port", DEFAULT_PORT)

    # Verify Databricks connection
    print_status("Verifying Databricks connection...")
    if not verify_databricks_connection(host, api_key):
        print_error("Failed to connect to Databricks workspace.")
        sys.exit(1)
    print_success("Databricks connection verified")

    # Start LiteLLM proxy
    proxy = start_litellm_proxy(port)
    proxy_started = proxy is not None

    try:
        # Test proxy health
        print_status("Testing LiteLLM proxy...")
        try:
            response = requests.get(f"http://localhost:{port}/health", timeout=5)
            if response.ok:
                print_success("LiteLLM proxy is healthy")
            else:
                print_error("LiteLLM proxy health check failed")
                sys.exit(1)
        except requests.RequestException:
            print_error("Cannot connect to LiteLLM proxy")
            sys.exit(1)

        # Test model inference
        print_status("Testing model inference...")
        try:
            response = requests.post(
                f"http://localhost:{port}/v1/chat/completions",
                json={
                    "model": config.get("model", DEFAULT_MODEL),
                    "messages": [{"role": "user", "content": "Say OK"}],
                    "max_tokens": 10,
                },
                timeout=60,
            )
            if response.ok and "choices" in response.json():
                print_success("Model inference successful")
            else:
                print_warning("Model inference test returned unexpected response")
        except requests.RequestException as e:
            print_warning(f"Model inference test failed: {e}")

        console.print()
        console.print(Panel(
            "[green]Validation complete![/green]\n\n"
            f"LiteLLM proxy is running on port {port}\n"
            "You can now use Aider or Continue.dev with Databricks LLMs.",
            title="Success",
            style="green",
        ))

    finally:
        if proxy_started and proxy:
            print_status("Stopping LiteLLM proxy...")
            proxy.terminate()
            proxy.wait()


@main.group()
def run():
    """Run an AI coding assistant with Databricks LLMs."""
    pass


@run.command()
@click.option("--port", default=None, type=int, help="LiteLLM proxy port")
@click.argument("aider_args", nargs=-1, type=click.UNPROCESSED)
def aider(port: int | None, aider_args: tuple):
    """Start Aider with Databricks LLM support.

    Any additional arguments are passed directly to Aider.

    Examples:
        databricks-code-assist run aider
        databricks-code-assist run aider -- --read myfile.py
        databricks-code-assist run aider -- file1.py file2.py
    """
    console.print(Panel("Starting Aider with Databricks LLM", style="blue"))

    host, api_key = get_databricks_credentials()
    if not host or not api_key:
        print_error("Credentials not found. Run 'databricks-code-assist setup' first.")
        sys.exit(1)

    config = get_config()
    port = port or config.get("port", DEFAULT_PORT)
    model = config.get("model", DEFAULT_MODEL)

    # Check Aider installation
    if not check_aider_installed():
        print_error("Aider is not installed.")
        print_status("Install it with: pip install aider-chat")
        print_status("Or: curl -LsSf https://aider.chat/install.sh | sh")
        sys.exit(1)

    # Generate Aider config in current directory
    project_dir = Path.cwd()
    aider_config = generate_aider_config(project_dir, port, model)
    print_success(f"Aider config created: {aider_config}")

    # Start LiteLLM proxy
    proxy = start_litellm_proxy(port)

    try:
        # Start Aider
        print_status("Starting Aider...")
        console.print()

        aider_cmd = ["aider", "--config", str(aider_config)]
        if aider_args:
            aider_cmd.extend(aider_args)

        result = subprocess.run(aider_cmd)
        sys.exit(result.returncode)

    except KeyboardInterrupt:
        print_status("\nStopping Aider...")
    finally:
        if proxy:
            print_status("Stopping LiteLLM proxy...")
            proxy.terminate()
            proxy.wait()


@run.command("continue")
@click.option("--port", default=None, type=int, help="LiteLLM proxy port")
def run_continue(port: int | None):
    """Setup Continue.dev with Databricks LLM support.

    This command:
    1. Starts the LiteLLM proxy
    2. Creates the Continue.dev configuration at ~/.continue/config.yaml
    3. Keeps the proxy running until you press Ctrl+C
    """
    console.print(Panel("Setting up Continue.dev with Databricks LLM", style="blue"))

    host, api_key = get_databricks_credentials()
    if not host or not api_key:
        print_error("Credentials not found. Run 'databricks-code-assist setup' first.")
        sys.exit(1)

    config = get_config()
    port = port or config.get("port", DEFAULT_PORT)
    model = config.get("model", DEFAULT_MODEL)

    # Generate Continue.dev config
    continue_config = generate_continue_config(port, model)
    print_success(f"Continue.dev config created: {continue_config}")

    # Start LiteLLM proxy
    proxy = start_litellm_proxy(port)

    console.print()
    console.print(Panel(
        f"[green]Continue.dev is ready![/green]\n\n"
        f"LiteLLM proxy running on port {port}\n\n"
        "Next steps:\n"
        "  1. Install Continue extension in VS Code\n"
        "  2. Press Cmd/Ctrl+I to open Continue panel\n"
        "  3. Select the Databricks model\n\n"
        "[yellow]Press Ctrl+C to stop the proxy[/yellow]",
        title="Ready",
        style="green",
    ))

    try:
        # Keep running until interrupted
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print_status("\nStopping...")
    finally:
        if proxy:
            proxy.terminate()
            proxy.wait()
        else:
            stop_litellm_proxy(port)


@main.command()
@click.option("--port", default=None, type=int, help="LiteLLM proxy port")
def stop(port: int | None):
    """Stop the LiteLLM proxy server."""
    config = get_config()
    port = port or config.get("port", DEFAULT_PORT)

    print_status(f"Stopping LiteLLM proxy on port {port}...")
    stop_litellm_proxy(port)
    print_success("Done")


@main.command()
def status():
    """Show the current configuration and proxy status."""
    console.print(Panel("Databricks Code Assist Status", style="blue"))

    # Configuration
    host, api_key = get_databricks_credentials()
    config = get_config()

    console.print("\n[bold]Configuration:[/bold]")
    console.print(f"  Config directory: {CONFIG_DIR}")
    console.print(f"  Host: {host or '[red]Not configured[/red]'}")
    console.print(f"  API Key: {'[green]Configured[/green]' if api_key else '[red]Not configured[/red]'}")
    console.print(f"  Model: {config.get('model', DEFAULT_MODEL)}")
    console.print(f"  Port: {config.get('port', DEFAULT_PORT)}")

    # Proxy status
    port = config.get("port", DEFAULT_PORT)
    console.print("\n[bold]Proxy Status:[/bold]")
    try:
        response = requests.get(f"http://localhost:{port}/health", timeout=2)
        if response.ok:
            console.print(f"  LiteLLM proxy: [green]Running on port {port}[/green]")
        else:
            console.print(f"  LiteLLM proxy: [red]Not healthy[/red]")
    except requests.RequestException:
        console.print(f"  LiteLLM proxy: [yellow]Not running[/yellow]")


if __name__ == "__main__":
    main()

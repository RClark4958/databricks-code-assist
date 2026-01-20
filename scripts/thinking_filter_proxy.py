#!/usr/bin/env python3
"""
Thinking Filter Proxy for Claude Code -> Databricks

This proxy strips "thinking" blocks from Anthropic API requests before
forwarding to LiteLLM. This is necessary because:

1. Claude Code sends requests with extended thinking enabled
2. Databricks Claude endpoints don't support the thinking blocks format
3. The thinking blocks in message history cause API errors

Architecture:
    Claude Code -> Filter Proxy (this) -> LiteLLM -> Databricks

The proxy:
- Listens on port 4001 (configurable)
- Strips thinking/redacted_thinking blocks from messages
- Forwards cleaned requests to LiteLLM on port 4010
- Passes through all other endpoints unchanged
"""

import copy
import json
import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse
import uvicorn
import argparse

app = FastAPI(title="Claude Code Thinking Filter Proxy")

# LiteLLM backend URL (set via command line)
LITELLM_URL = "http://localhost:4010"


def strip_thinking_from_messages(messages):
    """Remove thinking blocks from message content.

    Claude Code includes thinking blocks from previous turns in the message
    history. Databricks endpoints don't support this format, so we strip them.
    """
    if not messages:
        return messages

    cleaned = []
    for msg in messages:
        msg_copy = copy.deepcopy(msg)

        # Handle content that's a list of blocks
        if isinstance(msg_copy.get('content'), list):
            filtered_content = []
            for block in msg_copy['content']:
                # Skip thinking and redacted_thinking blocks
                if isinstance(block, dict):
                    block_type = block.get('type', '')
                    if block_type in ('thinking', 'redacted_thinking'):
                        continue
                filtered_content.append(block)

            # If all content was thinking blocks, keep a minimal placeholder
            if not filtered_content and msg_copy.get('role') == 'assistant':
                filtered_content = [{"type": "text", "text": "..."}]

            msg_copy['content'] = filtered_content

        cleaned.append(msg_copy)

    return cleaned


def strip_thinking_from_request(body: dict) -> dict:
    """Strip thinking-related params and content from request body."""
    body = copy.deepcopy(body)

    # Remove thinking parameter if present
    if 'thinking' in body:
        del body['thinking']

    # Strip thinking blocks from messages
    if 'messages' in body:
        body['messages'] = strip_thinking_from_messages(body['messages'])

    return body


@app.get("/health")
async def health_check():
    """Health check endpoint for proxy verification."""
    return {"status": "healthy", "service": "thinking-filter-proxy"}


@app.api_route("/v1/messages", methods=["POST"])
async def proxy_messages(request: Request):
    """Proxy /v1/messages requests, stripping thinking content."""

    # Read and parse request body
    body_bytes = await request.body()
    try:
        body = json.loads(body_bytes)
    except json.JSONDecodeError:
        body = {}

    # Strip thinking content
    filtered_body = strip_thinking_from_request(body)

    # Get headers (pass through most, but update content-length)
    headers = dict(request.headers)
    headers.pop('host', None)
    headers.pop('content-length', None)

    # Check if streaming
    is_streaming = filtered_body.get('stream', False)

    async with httpx.AsyncClient(timeout=300.0) as client:
        if is_streaming:
            # Stream the response
            async def stream_response():
                async with client.stream(
                    "POST",
                    f"{LITELLM_URL}/v1/messages",
                    json=filtered_body,
                    headers=headers,
                ) as response:
                    async for chunk in response.aiter_bytes():
                        yield chunk

            return StreamingResponse(
                stream_response(),
                media_type="text/event-stream",
            )
        else:
            # Non-streaming request
            response = await client.post(
                f"{LITELLM_URL}/v1/messages",
                json=filtered_body,
                headers=headers,
            )
            return Response(
                content=response.content,
                status_code=response.status_code,
                headers=dict(response.headers),
            )


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy_other(request: Request, path: str):
    """Proxy all other requests directly to LiteLLM without modification."""

    body = await request.body()
    headers = dict(request.headers)
    headers.pop('host', None)
    headers.pop('content-length', None)

    async with httpx.AsyncClient(timeout=300.0) as client:
        response = await client.request(
            method=request.method,
            url=f"{LITELLM_URL}/{path}",
            content=body,
            headers=headers,
            params=dict(request.query_params),
        )
        return Response(
            content=response.content,
            status_code=response.status_code,
            headers=dict(response.headers),
        )


def main():
    global LITELLM_URL

    parser = argparse.ArgumentParser(
        description="Thinking filter proxy for Claude Code -> Databricks"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=4001,
        help="Port to listen on (default: 4001)"
    )
    parser.add_argument(
        "--litellm-url",
        type=str,
        default="http://localhost:4010",
        help="LiteLLM backend URL (default: http://localhost:4010)"
    )
    parser.add_argument(
        "--host",
        type=str,
        default="127.0.0.1",
        help="Host to bind to (default: 127.0.0.1)"
    )
    args = parser.parse_args()

    LITELLM_URL = args.litellm_url

    print(f"Starting thinking filter proxy on {args.host}:{args.port}")
    print(f"Forwarding to LiteLLM at {LITELLM_URL}")

    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()

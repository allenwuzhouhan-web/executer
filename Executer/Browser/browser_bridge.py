#!/usr/bin/env python3
"""
Bridge between Executer (Swift) and browser-use (Python).
JSON-RPC 2.0 over stdin/stdout.

Launched by BrowserBridgeClient as:
    uv run --with browser-use --with playwright browser_bridge.py

Methods:
    initialize       — set API key, headless preference, LLM provider
    browser_task     — execute a multi-step browser task via natural language
    browser_extract  — extract structured data from a URL
    browser_screenshot — capture the browser's current view
    browser_session  — manage tabs, toggle visible/headless, close
"""

import sys
import json
import asyncio
import os
import time
import traceback
from pathlib import Path

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

_session = None          # BrowserSession instance (persistent)
_headless = True         # Default mode
_api_key = None          # LLM API key forwarded from Executer
_llm_provider = "deepseek"  # "anthropic", "openai", "deepseek"
_last_activity = 0.0     # Timestamp of last tool call
_idle_timeout = 600      # 10 minutes

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _log(msg: str):
    """Log to stderr (stdout is reserved for JSON-RPC)."""
    print(f"[BrowserBridge] {msg}", file=sys.stderr, flush=True)


def _send(obj: dict):
    """Send a JSON-RPC message to stdout."""
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()


def _error_response(req_id, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def _success_response(req_id, result) -> dict:
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


async def _ensure_playwright_installed():
    """Install Chromium if not already available."""
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            # Just check if chromium executable exists
            p.chromium.executable_path
    except Exception:
        _log("Installing Playwright Chromium (first-time setup)...")
        proc = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "playwright", "install", "chromium",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            _log("Playwright Chromium installed successfully.")
        else:
            _log(f"Playwright install failed: {stderr.decode()}")
            raise RuntimeError(f"Failed to install Playwright: {stderr.decode()}")


def _get_llm():
    """Create an LLM instance based on the configured provider and API key."""
    global _api_key, _llm_provider

    if _llm_provider == "openai":
        from langchain_openai import ChatOpenAI
        return ChatOpenAI(model="gpt-4o", api_key=_api_key)
    elif _llm_provider == "deepseek":
        from langchain_openai import ChatOpenAI
        return ChatOpenAI(
            model="deepseek-chat",
            api_key=_api_key,
            base_url="https://api.deepseek.com",
        )
    else:
        # Default: Anthropic
        from langchain_anthropic import ChatAnthropic
        return ChatAnthropic(model="claude-sonnet-4-20250514", api_key=_api_key)


async def _get_or_create_session(visible: bool = None):
    """Get or create a BrowserSession. Recreates if visibility changed."""
    global _session, _headless

    want_headless = not visible if visible is not None else _headless

    if _session is not None:
        # If visibility preference changed, close and recreate
        if want_headless != _headless:
            _log(f"Visibility changed — recreating session (headless={want_headless})")
            try:
                await _session.stop()
            except Exception:
                pass
            _session = None
            _headless = want_headless

    if _session is None:
        from browser_use import BrowserSession
        _headless = want_headless
        _session = BrowserSession(headless=_headless)
        await _session.start()
        _log(f"Browser session started (headless={_headless})")

    return _session


async def _close_session():
    """Close the active browser session."""
    global _session
    if _session is not None:
        try:
            await _session.stop()
        except Exception:
            pass
        _session = None
        _log("Browser session closed.")


# ---------------------------------------------------------------------------
# JSON-RPC Method Handlers
# ---------------------------------------------------------------------------

async def handle_initialize(params: dict) -> dict:
    """Initialize bridge with API key and preferences."""
    global _api_key, _headless, _llm_provider

    _api_key = params.get("api_key")
    _headless = params.get("headless", True)
    _llm_provider = params.get("llm_provider", "anthropic")

    await _ensure_playwright_installed()

    return {
        "protocolVersion": "2024-11-05",
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "browser-bridge", "version": "1.0"},
    }


async def handle_browser_task(params: dict) -> dict:
    """Execute a multi-step browser task using browser-use Agent."""
    from browser_use import Agent

    task = params.get("task", "")
    url = params.get("url")
    visible = params.get("visible")
    max_steps = params.get("max_steps", 20)

    if not task:
        return {"content": [{"type": "text", "text": "Error: 'task' parameter is required."}], "isError": True}

    session = await _get_or_create_session(visible=visible)

    # Navigate to starting URL if provided
    if url:
        await session.navigate_to(url)

    llm = _get_llm()
    agent = Agent(
        task=task,
        llm=llm,
        browser_session=session,
        max_steps=max_steps,
    )

    result = await agent.run()

    # Extract final result
    final_text = ""
    if hasattr(result, "final_result") and callable(result.final_result):
        final_text = result.final_result() or ""
    elif hasattr(result, "final_result"):
        final_text = str(result.final_result or "")
    else:
        final_text = str(result)

    steps_taken = 0
    if hasattr(result, "n_steps") and callable(result.n_steps):
        steps_taken = result.n_steps()
    elif hasattr(result, "n_steps"):
        steps_taken = result.n_steps

    return {
        "content": [{"type": "text", "text": final_text}],
        "isError": False,
        "_meta": {"steps": steps_taken},
    }


async def handle_browser_extract(params: dict) -> dict:
    """Extract data from a URL without a full agent loop."""
    url = params.get("url", "")
    instruction = params.get("instruction", "Extract the main text content of this page.")
    selector = params.get("selector")

    if not url:
        return {"content": [{"type": "text", "text": "Error: 'url' parameter is required."}], "isError": True}

    session = await _get_or_create_session(visible=False)
    await session.navigate_to(url)

    # Extract page content using browser-use's state method
    try:
        content = await session.get_state_as_text()
    except Exception as e:
        content = f"Extraction error: {e}"

    # Truncate if very long
    max_len = params.get("max_length", 10000)
    if len(content) > max_len:
        content = content[:max_len] + "\n... (truncated)"

    return {"content": [{"type": "text", "text": content}], "isError": False}


async def handle_browser_screenshot(params: dict) -> dict:
    """Capture a screenshot of the current browser view."""
    global _session
    if _session is None:
        return {"content": [{"type": "text", "text": "No active browser session."}], "isError": True}

    screenshot_dir = Path.home() / "Library" / "Application Support" / "Executer" / "browser_screenshots"
    screenshot_dir.mkdir(parents=True, exist_ok=True)
    path = screenshot_dir / f"browser_{int(time.time())}.png"

    await _session.take_screenshot(path=str(path))

    return {"content": [{"type": "text", "text": str(path)}], "isError": False}


async def handle_browser_session(params: dict) -> dict:
    """Manage browser session: list tabs, close, toggle visibility."""
    global _session, _headless

    action = params.get("action", "")

    if action == "list_tabs":
        if _session is None:
            return {"content": [{"type": "text", "text": "No active session. 0 tabs."}], "isError": False}
        try:
            pages = await _session.get_pages()
            tabs = []
            for i, p in enumerate(pages):
                url = await _session.get_current_page_url() if i == 0 else "unknown"
                title = await _session.get_current_page_title() if i == 0 else ""
                tabs.append(f"[{i}] {url} — {title}")
            return {"content": [{"type": "text", "text": "\n".join(tabs) if tabs else "No tabs open."}], "isError": False}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Error listing tabs: {e}"}], "isError": True}

    elif action == "close_tab":
        if _session is None:
            return {"content": [{"type": "text", "text": "No active session."}], "isError": True}
        tab_index = params.get("tab_index", -1)
        try:
            await _session.close_page(tab_index)
            return {"content": [{"type": "text", "text": f"Closed tab {tab_index}."}], "isError": False}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Error: {e}"}], "isError": True}

    elif action == "toggle_visible":
        new_headless = not _headless
        await _close_session()
        _headless = new_headless
        mode = "headless" if _headless else "visible"
        return {"content": [{"type": "text", "text": f"Browser mode toggled to {mode}. Will apply on next browser action."}], "isError": False}

    elif action == "close_all":
        await _close_session()
        return {"content": [{"type": "text", "text": "Browser session closed."}], "isError": False}

    else:
        return {"content": [{"type": "text", "text": f"Unknown action: {action}. Use: list_tabs, close_tab, toggle_visible, close_all"}], "isError": True}


# ---------------------------------------------------------------------------
# Idle Monitor
# ---------------------------------------------------------------------------

async def idle_monitor():
    """Close browser session after idle timeout."""
    global _last_activity, _session
    while True:
        await asyncio.sleep(60)
        if _session is not None and (time.time() - _last_activity) > _idle_timeout:
            _log(f"Idle timeout ({_idle_timeout}s) — closing browser session.")
            await _close_session()


# ---------------------------------------------------------------------------
# Main JSON-RPC Loop
# ---------------------------------------------------------------------------

METHODS = {
    "initialize": handle_initialize,
    "tools/call": None,  # Dispatched by tool name
}

TOOLS = {
    "browser_task": handle_browser_task,
    "browser_extract": handle_browser_extract,
    "browser_screenshot": handle_browser_screenshot,
    "browser_session": handle_browser_session,
}


async def dispatch(message: dict) -> dict | None:
    """Dispatch a JSON-RPC request and return a response."""
    global _last_activity
    _last_activity = time.time()

    req_id = message.get("id")
    method = message.get("method", "")
    params = message.get("params", {})

    # Handle notifications (no id) — just ack
    if req_id is None:
        return None

    try:
        if method == "initialize":
            result = await handle_initialize(params)
            return _success_response(req_id, result)

        elif method == "tools/call":
            tool_name = params.get("name", "")
            tool_args = params.get("arguments", {})
            handler = TOOLS.get(tool_name)
            if handler is None:
                return _error_response(req_id, -32601, f"Unknown tool: {tool_name}")
            result = await handler(tool_args)
            return _success_response(req_id, result)

        else:
            return _error_response(req_id, -32601, f"Unknown method: {method}")

    except Exception as e:
        _log(f"Error handling {method}: {traceback.format_exc()}")
        return _error_response(req_id, -32000, str(e))


async def main():
    _log("Starting browser bridge...")

    # Start idle monitor
    asyncio.create_task(idle_monitor())

    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    transport, _ = await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
    )

    while True:
        line = await reader.readline()
        if not line:
            break  # EOF

        line = line.strip()
        if not line:
            continue

        try:
            message = json.loads(line)
        except json.JSONDecodeError as e:
            _log(f"Invalid JSON: {e}")
            continue

        response = await dispatch(message)
        if response is not None:
            _send(response)

    # Cleanup
    await _close_session()
    _log("Bridge shutdown.")


if __name__ == "__main__":
    asyncio.run(main())

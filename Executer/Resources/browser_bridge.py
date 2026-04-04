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

_session = None          # BrowserSession instance (for browser_task/extract)
_headless = True         # Default mode
_api_key = None          # LLM API key forwarded from Executer
_llm_provider = "deepseek"  # "anthropic", "openai", "deepseek"
_last_activity = 0.0     # Timestamp of last tool call
_idle_timeout = 600      # 10 minutes

# Playwright-direct instances (for Stage 5 DOM tools — fast & reliable)
_pw = None               # Playwright instance
_pw_browser = None       # Playwright Browser
_pw_page = None          # Current Playwright Page

# CDP connection state (for connecting to user's real Chrome)
_cdp_browser = None      # Playwright Browser connected via CDP
_cdp_page = None         # Current CDP-connected Page
_cdp_connected = False   # Whether we have an active CDP connection

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


_llm_instance = None
_llm_config_key = None  # (provider, api_key) tuple for cache invalidation


def _get_llm():
    """Get or create a cached LLM instance. Invalidates on provider/key change."""
    global _api_key, _llm_provider, _llm_instance, _llm_config_key

    config_key = (_llm_provider, _api_key)
    if _llm_instance is not None and _llm_config_key == config_key:
        return _llm_instance

    if _llm_provider == "openai":
        from langchain_openai import ChatOpenAI
        llm = ChatOpenAI(model="gpt-4o", api_key=_api_key)
    elif _llm_provider == "deepseek":
        from langchain_openai import ChatOpenAI
        llm = ChatOpenAI(
            model="deepseek-chat",
            api_key=_api_key,
            base_url="https://api.deepseek.com",
        )
    else:
        # Default: Anthropic
        from langchain_anthropic import ChatAnthropic
        llm = ChatAnthropic(model="claude-sonnet-4-20250514", api_key=_api_key)

    _llm_instance = llm
    _llm_config_key = config_key
    return llm


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


async def _get_pw_page():
    """Get or create a Playwright page. CDP-connected page takes priority."""
    global _pw, _pw_browser, _pw_page, _cdp_page, _cdp_connected

    # CDP path: if connected to real Chrome, use that page
    if _cdp_connected and _cdp_page is not None:
        try:
            await _cdp_page.title()
            return _cdp_page
        except Exception:
            # CDP page died — try to recover from browser contexts
            _cdp_page = None
            if _cdp_browser:
                for ctx in _cdp_browser.contexts:
                    if ctx.pages:
                        _cdp_page = ctx.pages[0]
                        _log("CDP page recovered from context")
                        return _cdp_page
            # Can't recover — fall through to launched browser
            _cdp_connected = False
            _log("CDP connection lost, falling back to launched browser")

    # Standard path: launch our own Playwright Chromium
    if _pw_page is not None:
        try:
            await _pw_page.title()
            return _pw_page
        except Exception:
            _pw_page = None

    if _pw is None:
        from playwright.async_api import async_playwright
        _pw = await async_playwright().start()
        _log("Playwright started (direct)")

    if _pw_browser is None:
        _pw_browser = await _pw.chromium.launch(headless=_headless)
        _log(f"Playwright browser launched (headless={_headless})")

    if _pw_page is None:
        _pw_page = await _pw_browser.new_page()
        # Reset listener flags — old page's listeners are gone
        global _console_listener_installed, _network_intercepting, _network_listener
        _console_listener_installed = False
        _network_intercepting = False
        _network_listener = None
        _log("New Playwright page created")

    return _pw_page


async def _close_cdp():
    """Close CDP connection to real Chrome."""
    global _cdp_browser, _cdp_page, _cdp_connected
    if _cdp_browser:
        try:
            # disconnect() detaches without closing the user's Chrome
            await _cdp_browser.close()
        except Exception:
            pass
        _cdp_browser = None
        _cdp_page = None
        _cdp_connected = False
        _log("CDP connection closed.")


async def _close_pw():
    """Close Playwright browser and CDP connection."""
    global _pw, _pw_browser, _pw_page
    await _close_cdp()
    if _pw_browser:
        try:
            await _pw_browser.close()
        except Exception:
            pass
        _pw_browser = None
        _pw_page = None
    if _pw:
        try:
            await _pw.stop()
        except Exception:
            pass
        _pw = None
        _log("Playwright closed.")


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

    # Build URL trail from AgentHistoryList
    trail = []
    seen_urls = set()
    if hasattr(result, "history"):
        for item in result.history:
            state = getattr(item, "state", None)
            step_url = getattr(state, "url", None) if state else None
            step_title = getattr(state, "title", None) if state else None
            if not step_url or step_url in seen_urls:
                continue
            # Skip blank/internal pages
            if step_url in ("about:blank", "chrome://newtab/", "data:,"):
                continue
            seen_urls.add(step_url)
            # Collect extracted content from this step's action results
            summary_parts = []
            for r in (item.result if hasattr(item, "result") and item.result else []):
                ec = getattr(r, "extracted_content", None)
                if ec:
                    summary_parts.append(str(ec))
            summary = " ".join(summary_parts).strip()
            trail.append({
                "url": step_url,
                "title": (step_title or "")[:120],
                "summary": summary[:200],
            })

    return {
        "content": [{"type": "text", "text": final_text}],
        "isError": False,
        "_meta": {"steps": steps_taken, "trail": trail},
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
                try:
                    url = p.url or "about:blank"
                    title = await p.title() if hasattr(p, 'title') else ""
                except Exception:
                    url = "unknown"
                    title = ""
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
    """Close all browser resources after idle timeout."""
    global _last_activity, _session
    while True:
        await asyncio.sleep(60)
        if (_session is not None or _pw_browser is not None or _cdp_connected) and (time.time() - _last_activity) > _idle_timeout:
            _log(f"Idle timeout ({_idle_timeout}s) — closing all browsers.")
            await _close_session()
            await _close_pw()  # Also closes CDP


# ---------------------------------------------------------------------------
# Browser Intelligence Handlers (Stage 5) — Uses Playwright DIRECTLY (not browser-use)
# ---------------------------------------------------------------------------

_console_logs = []
_console_listener_installed = False
_network_log = []
_network_intercepting = False
_network_listener = None  # Current response listener (for removal on re-start)
REDACTED_HEADERS = {"authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token"}


async def handle_browser_execute_js(params: dict) -> dict:
    page = await _get_pw_page()
    code = params.get("code", "")
    timeout_ms = params.get("timeout_ms", 5000)
    try:
        result = await asyncio.wait_for(page.evaluate(code), timeout=timeout_ms / 1000.0)
        text = json.dumps(result, ensure_ascii=False, default=str)
        if len(text) > 10000:
            text = text[:10000] + "\n... [truncated]"
        return {"content": [{"type": "text", "text": text}], "isError": False}
    except asyncio.TimeoutError:
        return {"content": [{"type": "text", "text": "JS timed out."}], "isError": True}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"JS error: {e}"}], "isError": True}


async def handle_browser_read_dom(params: dict) -> dict:
    page = await _get_pw_page()
    selector = params.get("selector", "body")
    max_depth = params.get("max_depth", 5)
    include_text = params.get("include_text", True)
    # Use json.dumps for safe selector escaping (prevents JS injection)
    selector_js = json.dumps(selector)
    js_code = """
    (function() {
        function t(el, d, mx) {
            if (d > mx) return null;
            var tag = el.tagName ? el.tagName.toLowerCase() : '';
            var id = el.id ? '#' + el.id : '';
            var cls = el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\\s+/).join('.') : '';
            var txt = '';
            if (%s) { for (var c of el.childNodes) { if (c.nodeType === 3 && c.textContent.trim()) { txt = c.textContent.trim().substring(0, 100); break; } } }
            var a = '';
            if (el.type) a += ' type="' + el.type + '"';
            if (el.name) a += ' name="' + el.name + '"';
            if (el.value && el.value.length < 100) a += ' value="' + el.value + '"';
            if (el.href) a += ' href="' + el.href.substring(0, 80) + '"';
            if (el.placeholder) a += ' placeholder="' + el.placeholder + '"';
            var ch = [];
            for (var c of el.children) { var r = t(c, d+1, mx); if (r) ch.push(r); }
            return {tag: tag+id+cls, text: txt, attrs: a.trim(), children: ch};
        }
        var sel = %s;
        var root = document.querySelector(sel);
        if (!root) return 'Element not found: ' + sel;
        return t(root, 0, %d);
    })()
    """ % ('true' if include_text else 'false', selector_js, max_depth)
    try:
        result = await page.evaluate(js_code)
        text = json.dumps(result, ensure_ascii=False, indent=1, default=str)
        if len(text) > 15000:
            text = text[:15000] + "\n... [truncated]"
        return {"content": [{"type": "text", "text": text}], "isError": False}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"DOM error: {e}"}], "isError": True}


async def handle_browser_get_console(params: dict) -> dict:
    global _console_listener_installed, _console_logs
    page = await _get_pw_page()
    if not _console_listener_installed:
        page.on("console", lambda msg: _console_logs.append({"level": msg.type, "text": msg.text[:500]}) or (len(_console_logs) > 100 and _console_logs.pop(0)))
        _console_listener_installed = True
    level = params.get("level", "all")
    limit = params.get("limit", 50)
    logs = _console_logs[-limit:]
    if level != "all":
        logs = [l for l in logs if l["level"] == level]
    text = "\n".join(f"[{l['level']}] {l['text']}" for l in logs) or "No console messages."
    return {"content": [{"type": "text", "text": text}], "isError": False}


async def handle_browser_inspect_element(params: dict) -> dict:
    page = await _get_pw_page()
    selector = params.get("selector", "")
    if not selector:
        return {"content": [{"type": "text", "text": "No selector."}], "isError": True}
    # Use json.dumps for safe selector escaping (prevents JS injection)
    selector_js = json.dumps(selector)
    js_code = """(function() { var sel = %s; var el = document.querySelector(sel); if (!el) return 'Not found: ' + sel; var r = el.getBoundingClientRect(); var s = window.getComputedStyle(el); return {tag:el.tagName, id:el.id, cls:el.className, text:(el.textContent||'').trim().substring(0,200), value:el.value||'', bounds:{x:r.x,y:r.y,w:r.width,h:r.height}, visible:r.width>0&&r.height>0, display:s.display, color:s.color, bg:s.backgroundColor, font:s.fontSize}; })()""" % selector_js
    try:
        result = await page.evaluate(js_code)
        return {"content": [{"type": "text", "text": json.dumps(result, indent=1, default=str)}], "isError": False}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Inspect error: {e}"}], "isError": True}


async def handle_browser_click_element_css(params: dict) -> dict:
    page = await _get_pw_page()
    selector = params.get("selector", "")
    if not selector:
        return {"content": [{"type": "text", "text": "No selector."}], "isError": True}
    try:
        await page.click(selector, timeout=5000)
        return {"content": [{"type": "text", "text": f"Clicked '{selector}'."}], "isError": False}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Click failed: {e}"}], "isError": True}


async def handle_browser_type_in_element(params: dict) -> dict:
    page = await _get_pw_page()
    selector = params.get("selector", "")
    text = params.get("text", "")
    clear_first = params.get("clear_first", True)
    if not selector:
        return {"content": [{"type": "text", "text": "No selector."}], "isError": True}
    try:
        if clear_first:
            await page.fill(selector, text, timeout=5000)
        else:
            await page.type(selector, text, timeout=5000)
        return {"content": [{"type": "text", "text": f"Typed into '{selector}'."}], "isError": False}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Type failed: {e}"}], "isError": True}


async def handle_browser_intercept_network(params: dict) -> dict:
    global _network_intercepting, _network_log, _network_listener
    page = await _get_pw_page()
    action = params.get("action", "get_log")
    if action == "start":
        # Remove previous listener to prevent accumulation
        if _network_listener is not None:
            try:
                page.remove_listener("response", _network_listener)
            except Exception:
                pass
        _network_log = []
        _network_intercepting = True
        async def on_resp(response):
            if not _network_intercepting: return
            h = {k: ("[REDACTED]" if k.lower() in REDACTED_HEADERS else v[:200]) for k, v in (response.headers or {}).items()}
            _network_log.append({"url": response.url[:200], "status": response.status, "method": response.request.method, "headers": h})
            if len(_network_log) > 50: _network_log.pop(0)
        _network_listener = on_resp
        page.on("response", on_resp)
        return {"content": [{"type": "text", "text": "Network interception started."}], "isError": False}
    elif action == "stop":
        _network_intercepting = False
        if _network_listener is not None:
            try:
                page.remove_listener("response", _network_listener)
            except Exception:
                pass
            _network_listener = None
        return {"content": [{"type": "text", "text": f"Stopped. {len(_network_log)} entries."}], "isError": False}
    elif action == "get_log":
        if not _network_log:
            return {"content": [{"type": "text", "text": "No entries."}], "isError": False}
        text = json.dumps(_network_log[-30:], indent=1, default=str)
        return {"content": [{"type": "text", "text": text[:10000]}], "isError": False}
    return {"content": [{"type": "text", "text": f"Unknown action: {action}"}], "isError": True}


async def handle_browser_navigate(params: dict) -> dict:
    """Navigate the Playwright browser to a URL."""
    page = await _get_pw_page()
    url = params.get("url", "")
    if not url:
        return {"content": [{"type": "text", "text": "No URL provided."}], "isError": True}
    try:
        await page.goto(url, wait_until="domcontentloaded", timeout=15000)
        title = await page.title()
        return {"content": [{"type": "text", "text": f"Navigated to {url}. Title: {title}"}], "isError": False}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Navigation failed: {e}"}], "isError": True}


# ---------------------------------------------------------------------------
# CDP Connection Handlers — Connect to user's real Chrome browser
# ---------------------------------------------------------------------------

async def handle_connect_chrome(params: dict) -> dict:
    """Connect Playwright to user's real Chrome via CDP."""
    global _pw, _cdp_browser, _cdp_page, _cdp_connected

    cdp_url = params.get("cdp_url", "http://localhost:9222")
    url_pattern = params.get("url_pattern", "")

    # Close any existing CDP connection
    await _close_cdp()

    # Ensure Playwright is started
    if _pw is None:
        from playwright.async_api import async_playwright
        _pw = await async_playwright().start()
        _log("Playwright started for CDP")

    # Connect to Chrome via CDP
    try:
        _cdp_browser = await _pw.chromium.connect_over_cdp(cdp_url)
    except Exception as e:
        return {"content": [{"type": "text", "text":
            f"CDP connection failed: {e}\n"
            f"Ensure Chrome is running with: --remote-debugging-port=9222"}],
            "isError": True}

    # Get all pages from all contexts
    all_pages = []
    for context in _cdp_browser.contexts:
        all_pages.extend(context.pages)

    if not all_pages:
        return {"content": [{"type": "text", "text": "Connected to Chrome but no tabs found."}], "isError": True}

    # Select page by URL pattern, or use first
    _cdp_page = all_pages[0]
    if url_pattern:
        for page in all_pages:
            if url_pattern.lower() in page.url.lower():
                _cdp_page = page
                break

    _cdp_connected = True

    # Reset listener flags for new page
    global _console_listener_installed, _network_intercepting, _network_listener
    _console_listener_installed = False
    _network_intercepting = False
    _network_listener = None

    title = await _cdp_page.title()
    tab_list = "\n".join(f"  [{i}] {p.url[:100]}" for i, p in enumerate(all_pages))

    _log(f"CDP connected: {len(all_pages)} tabs, active={_cdp_page.url[:80]}")

    return {"content": [{"type": "text", "text":
        f"Connected to Chrome via CDP. {len(all_pages)} tab(s).\n"
        f"Active tab: {_cdp_page.url}\n"
        f"Title: {title}\n"
        f"All tabs:\n{tab_list}"}], "isError": False}


async def handle_read_elements(params: dict) -> dict:
    """Read all interactive elements with indices for reliable clicking."""
    page = await _get_pw_page()
    scope = params.get("scope", "body")

    js = """(function() {
        var root = document.querySelector('%s');
        if (!root) return 'ERR:Scope not found';
        var sels = 'button, input, select, textarea, a[href], [role="button"], [role="option"], [role="menuitem"], [role="radio"], [role="checkbox"], [role="link"], [onclick], [tabindex="0"], label[for]';
        var els = root.querySelectorAll(sels);
        var results = [];
        for (var i = 0; i < els.length && i < 120; i++) {
            var el = els[i];
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;
            if (rect.bottom < 0 || rect.top > window.innerHeight) continue;
            var text = (el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || el.title || '').trim().substring(0, 100);
            var tag = el.tagName.toLowerCase();
            var type = el.type || el.getAttribute('role') || '';
            el.setAttribute('data-exec-idx', i);
            results.push(i + '|' + tag + '|' + type + '|' + text + '|' + Math.round(rect.left) + ',' + Math.round(rect.top) + ',' + Math.round(rect.width) + 'x' + Math.round(rect.height));
        }
        return results.join('\\n');
    })()""" % scope.replace("'", "\\'")

    try:
        raw = await page.evaluate(js)
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Read elements error: {e}"}], "isError": True}

    if isinstance(raw, str) and raw.startswith("ERR:"):
        return {"content": [{"type": "text", "text": raw[4:]}], "isError": True}

    if not raw:
        return {"content": [{"type": "text", "text": "No interactive elements found on page."}], "isError": False}

    lines = raw.strip().split('\n')
    output = [f"Interactive elements ({len(lines)}):"]
    output.append("idx | tag    | type   | text                    | position")
    output.append("--- | ------ | ------ | ----------------------- | --------")
    for line in lines:
        parts = line.split('|', 4)
        if len(parts) < 5:
            continue
        parts = [p.strip() for p in parts]
        idx = parts[0].ljust(3)
        tag = parts[1].ljust(6)
        tp = parts[2][:6].ljust(6)
        text = parts[3][:23].ljust(23)
        output.append(f"{idx} | {tag} | {tp} | {text} | {parts[4]}")

    return {"content": [{"type": "text", "text": "\n".join(output)}], "isError": False}


async def handle_click_element(params: dict) -> dict:
    """Click an element by index (from read_elements), text, or CSS selector."""
    page = await _get_pw_page()
    index = params.get("index")
    text = params.get("text")
    selector = params.get("selector")

    if index is not None:
        js = """(function() {
            var el = document.querySelector('[data-exec-idx="%d"]');
            if (!el) return 'ERR:Element #%d not found. Run browser_read_elements again.';
            el.scrollIntoView({block: 'center'});
            el.focus();
            el.click();
            var tag = el.tagName.toLowerCase();
            var t = (el.innerText || el.value || '').trim().substring(0, 60);
            return 'Clicked ' + tag + ': ' + t;
        })()""" % (index, index)
        try:
            result = await page.evaluate(js)
            if isinstance(result, str) and result.startswith("ERR:"):
                return {"content": [{"type": "text", "text": result[4:]}], "isError": True}
            return {"content": [{"type": "text", "text": result}], "isError": False}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Click error: {e}"}], "isError": True}

    elif text:
        escaped = text.replace("\\", "\\\\").replace("'", "\\'")
        js = """(function() {
            var target = '%s'.toLowerCase();
            var all = document.querySelectorAll('button, a, input, [role="button"], [role="option"], [role="radio"], label, [onclick], [tabindex="0"]');
            for (var i = 0; i < all.length; i++) {
                var el = all[i];
                var elText = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().toLowerCase();
                if (elText.indexOf(target) !== -1 || elText === target) {
                    var rect = el.getBoundingClientRect();
                    if (rect.width > 0 && rect.height > 0) {
                        el.scrollIntoView({block: 'center'});
                        el.focus();
                        el.click();
                        return 'Clicked: ' + el.tagName.toLowerCase() + ' "' + elText.substring(0, 60) + '"';
                    }
                }
            }
            return 'ERR:No visible element contains text: ' + target;
        })()""" % escaped
        try:
            result = await page.evaluate(js)
            if isinstance(result, str) and result.startswith("ERR:"):
                return {"content": [{"type": "text", "text": result[4:]}], "isError": True}
            return {"content": [{"type": "text", "text": result}], "isError": False}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Click error: {e}"}], "isError": True}

    elif selector:
        try:
            await page.click(selector, timeout=5000)
            return {"content": [{"type": "text", "text": f"Clicked '{selector}'."}], "isError": False}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Click failed: {e}"}], "isError": True}

    else:
        return {"content": [{"type": "text", "text": "Provide one of: index, text, or selector."}], "isError": True}


async def handle_type_element(params: dict) -> dict:
    """Type text into an input. React-compatible with native setter + event dispatch."""
    page = await _get_pw_page()
    text = params.get("text", "")
    index = params.get("index")
    selector = params.get("selector")
    clear_first = params.get("clear_first", True)

    if not text:
        return {"content": [{"type": "text", "text": "No text provided."}], "isError": True}

    escaped = text.replace("\\", "\\\\").replace("'", "\\'")

    # Build element finder
    if index is not None:
        find_el = 'document.querySelector(\'[data-exec-idx="%d"]\')' % index
    elif selector:
        sel = selector.replace("'", "\\'")
        find_el = "document.querySelector('%s')" % sel
    else:
        find_el = ("document.activeElement && "
                   "(document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA') "
                   "? document.activeElement "
                   ": document.querySelector('input:not([type=hidden]):not([type=submit]):not([type=button]), textarea')")

    clear_js = "el.value = '';" if clear_first else ""
    val_expr = "'%s'" % escaped if clear_first else "el.value + '%s'" % escaped

    js = """(function() {
        var el = %s;
        if (!el) return 'ERR:No input field found. Use browser_read_elements to find inputs.';
        el.scrollIntoView({block: 'center'});
        el.focus();
        %s
        var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
                        || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
        if (nativeSetter && nativeSetter.set) {
            nativeSetter.set.call(el, %s);
        } else {
            el.value = %s;
        }
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return 'Typed "' + '%s'.substring(0, 40) + '" into ' + el.tagName.toLowerCase();
    })()""" % (find_el, clear_js, val_expr, val_expr, escaped)

    try:
        result = await page.evaluate(js)
        if isinstance(result, str) and result.startswith("ERR:"):
            return {"content": [{"type": "text", "text": result[4:]}], "isError": True}
        return {"content": [{"type": "text", "text": result}], "isError": False}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Type error: {e}"}], "isError": True}


async def handle_disconnect_chrome(params: dict) -> dict:
    """Disconnect from real Chrome. Browser tools revert to launched Chromium."""
    await _close_cdp()
    return {"content": [{"type": "text", "text": "Disconnected from Chrome CDP."}], "isError": False}


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
    "browser_execute_js": handle_browser_execute_js,
    "browser_read_dom": handle_browser_read_dom,
    "browser_get_console": handle_browser_get_console,
    "browser_inspect_element": handle_browser_inspect_element,
    "browser_click_element_css": handle_browser_click_element_css,
    "browser_type_in_element": handle_browser_type_in_element,
    "browser_intercept_network": handle_browser_intercept_network,
    "browser_navigate": handle_browser_navigate,
    # CDP connection tools
    "browser_connect_chrome": handle_connect_chrome,
    "browser_read_elements": handle_read_elements,
    "browser_click_element": handle_click_element,
    "browser_type_element": handle_type_element,
    "browser_disconnect_chrome": handle_disconnect_chrome,
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

    # Cleanup — close both browser-use session and Playwright
    await _close_session()
    await _close_pw()
    _log("Bridge shutdown.")


if __name__ == "__main__":
    asyncio.run(main())

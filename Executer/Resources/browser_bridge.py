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
            req = response.request
            _network_log.append({"url": response.url[:200], "status": response.status, "method": req.method if req else "UNKNOWN", "headers": h})
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
    """Read all interactive elements with indices, state, and visibility info."""
    page = await _get_pw_page()
    scope = params.get("scope", "body")
    include_iframes = params.get("include_iframes", True)

    # Comprehensive element reader — includes disabled/checked/readonly state,
    # visibility verification, iframe traversal, form values, and SECTION CONTEXT.
    # Each element includes its nearest labeled container ancestor so the LLM
    # understands spatial hierarchy (e.g., "Create Page" under "Private" section).
    js = """(function() {
        var root = document.querySelector('%s');
        if (!root) return JSON.stringify({error: 'Scope not found'});
        var sels = 'button, input, select, textarea, a[href], [role="button"], [role="option"], [role="menuitem"], [role="radio"], [role="checkbox"], [role="link"], [onclick], [tabindex="0"], label[for], [contenteditable="true"]';
        var results = [];
        var idx = 0;

        function isVisible(el) {
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) return false;
            var style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (parseFloat(style.opacity) < 0.1) return false;
            if (style.pointerEvents === 'none' && el.tagName !== 'LABEL') return false;
            return true;
        }

        // Walk up DOM to find labeled container ancestors (sections, nav, groups, menus).
        // Returns ancestry path like "Sidebar > Private" so agent knows the context.
        function getSectionPath(el) {
            var labels = [];
            var p = el.parentElement;
            var depth = 0;
            while (p && p !== document.body && depth < 8) {
                var role = p.getAttribute('role') || '';
                var tag = p.tagName.toLowerCase();
                var isContainer = (
                    role === 'navigation' || role === 'menu' || role === 'menubar' ||
                    role === 'toolbar' || role === 'tablist' || role === 'dialog' ||
                    role === 'group' || role === 'region' || role === 'complementary' ||
                    role === 'banner' || role === 'main' || role === 'contentinfo' ||
                    tag === 'nav' || tag === 'section' || tag === 'aside' ||
                    tag === 'header' || tag === 'footer' || tag === 'main' ||
                    tag === 'form' || tag === 'fieldset' || tag === 'menu' ||
                    tag === 'details' || tag === 'dialog'
                );
                if (isContainer) {
                    var lbl = p.getAttribute('aria-label') || p.getAttribute('title') ||
                              p.getAttribute('aria-labelledby');
                    if (lbl && p.getAttribute('aria-labelledby')) {
                        var lblEl = document.getElementById(lbl);
                        lbl = lblEl ? (lblEl.innerText || '').trim().substring(0, 40) : lbl;
                    }
                    // Fallback: check for a heading or legend child as the section label
                    if (!lbl) {
                        var heading = p.querySelector(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > legend, :scope > [role="heading"]');
                        if (heading) lbl = (heading.innerText || '').trim().substring(0, 40);
                    }
                    if (lbl) {
                        labels.push(lbl);
                    } else if (role) {
                        labels.push(role);
                    }
                }
                p = p.parentElement;
                depth++;
            }
            labels.reverse();
            return labels.length > 0 ? labels.join(' > ') : '';
        }

        function processElements(doc, prefix) {
            var els = doc.querySelectorAll(sels);
            for (var i = 0; i < els.length && idx < 150; i++) {
                var el = els[i];
                if (!isVisible(el)) continue;
                var rect = el.getBoundingClientRect();
                var text = (el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || el.title || '').trim().substring(0, 120);
                var tag = el.tagName.toLowerCase();
                var type = el.type || el.getAttribute('role') || '';

                // State flags
                var flags = [];
                if (el.disabled || el.getAttribute('aria-disabled') === 'true') flags.push('DISABLED');
                if (el.readOnly) flags.push('readonly');
                if (el.checked) flags.push('checked');
                if (el.getAttribute('aria-expanded') === 'true') flags.push('expanded');
                if (el.getAttribute('aria-selected') === 'true') flags.push('selected');
                if (el.required) flags.push('required');

                // For inputs, show current value
                var val = '';
                if ((tag === 'input' || tag === 'textarea') && el.value) {
                    val = el.value.substring(0, 40);
                }
                if (tag === 'select' && el.selectedIndex >= 0) {
                    val = (el.options[el.selectedIndex].text || '').substring(0, 40);
                }

                // Section context — where this element lives in the page hierarchy
                var section = getSectionPath(el);

                el.setAttribute('data-exec-idx', idx);
                var pos = Math.round(rect.left) + ',' + Math.round(rect.top) + ',' + Math.round(rect.width) + 'x' + Math.round(rect.height);
                results.push({i: idx, tag: tag, type: type, text: text, pos: pos, flags: flags.join(','), val: val, prefix: prefix || '', section: section});
                idx++;
            }
        }

        processElements(root, '');

        // Traverse iframes
        if (%s) {
            var iframes = root.querySelectorAll('iframe');
            for (var f = 0; f < iframes.length && f < 5; f++) {
                try {
                    var fdoc = iframes[f].contentDocument || iframes[f].contentWindow.document;
                    if (fdoc) processElements(fdoc, 'iframe' + f + ':');
                } catch(e) { /* cross-origin iframe, skip */ }
            }
        }

        return JSON.stringify({elements: results, url: window.location.href, title: document.title});
    })()""" % (scope.replace("'", "\\'"), 'true' if include_iframes else 'false')

    try:
        raw = await page.evaluate(js)
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Read elements error: {e}"}], "isError": True}

    # Parse JSON result
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except (json.JSONDecodeError, TypeError):
        data = None

    if isinstance(data, dict) and "error" in data:
        return {"content": [{"type": "text", "text": data["error"]}], "isError": True}

    if not data or not data.get("elements"):
        return {"content": [{"type": "text", "text": "No interactive elements found on page."}], "isError": False}

    elements = data["elements"]
    page_url = data.get("url", "")
    page_title = data.get("title", "")

    output = [f"Page: {page_title} ({page_url})"]
    output.append(f"Interactive elements ({len(elements)}):")

    # Group elements by section for spatial context
    from collections import OrderedDict
    sections = OrderedDict()
    for el in elements:
        section = el.get("section", "") or ""
        if section not in sections:
            sections[section] = []
        sections[section].append(el)

    for section, els in sections.items():
        if section:
            output.append(f"── {section}")
            indent = "   "
        else:
            indent = ""

        for el in els:
            prefix = el.get("prefix", "")
            idx_str = (prefix + str(el["i"])).ljust(3)
            tag = el["tag"][:6].ljust(6)
            tp = el["type"][:6].ljust(6)
            text = el["text"][:28].ljust(28)
            flags = el.get("flags", "")[:11].ljust(11)
            val = el.get("val", "")[:20]
            output.append(f"{indent}{idx_str} | {tag} | {tp} | {text} | {flags} | {val}")

    return {"content": [{"type": "text", "text": "\n".join(output)}], "isError": False}


async def handle_click_element(params: dict) -> dict:
    """Click element with visibility verification, full event dispatch, and effect detection."""
    page = await _get_pw_page()
    index = params.get("index")
    text = params.get("text")
    selector = params.get("selector")
    wait_ms = params.get("wait_after", 300)

    # Shared robust click JS — checks visibility, dispatches full event chain,
    # detects page changes (URL, new modals, DOM mutations).
    CLICK_JS = """
    (function(el) {
        // 1. Visibility check
        var rect = el.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) return {error: 'Element has zero size (hidden)'};
        var style = window.getComputedStyle(el);
        if (style.display === 'none') return {error: 'Element has display:none'};
        if (style.visibility === 'hidden') return {error: 'Element has visibility:hidden'};
        if (parseFloat(style.opacity) < 0.1) return {error: 'Element has opacity near 0'};
        if (style.pointerEvents === 'none') return {error: 'Element has pointer-events:none'};

        // 2. Disabled check
        if (el.disabled || el.getAttribute('aria-disabled') === 'true')
            return {error: 'Element is DISABLED. Check if prerequisites are met.'};

        // 3. Snapshot pre-click state
        var urlBefore = window.location.href;
        var modalsBefore = document.querySelectorAll('[role="dialog"], [role="alertdialog"], .modal, .popup').length;

        // 4. Scroll into view and click with full event chain
        el.scrollIntoView({block: 'center', behavior: 'instant'});
        el.focus();
        // Recapture rect AFTER scroll — old rect has stale coordinates
        rect = el.getBoundingClientRect();
        var cx = rect.left + rect.width / 2;
        var cy = rect.top + rect.height / 2;
        // Dispatch mousemove/pointermove first so the browser registers cursor position
        el.dispatchEvent(new PointerEvent('pointermove', {bubbles: true, clientX: cx, clientY: cy}));
        el.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, clientX: cx, clientY: cy}));
        el.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, clientX: cx, clientY: cy}));
        el.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: cx, clientY: cy}));
        el.dispatchEvent(new PointerEvent('pointerup', {bubbles: true, clientX: cx, clientY: cy}));
        el.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, clientX: cx, clientY: cy}));
        el.click();

        // 5. Detect effects
        var tag = el.tagName.toLowerCase();
        var t = (el.innerText || el.value || '').trim().substring(0, 60);
        var effects = [];
        if (window.location.href !== urlBefore) effects.push('page navigated to ' + window.location.href);
        var modalsAfter = document.querySelectorAll('[role="dialog"], [role="alertdialog"], .modal, .popup').length;
        if (modalsAfter > modalsBefore) effects.push('modal/popup appeared');
        if (modalsAfter < modalsBefore) effects.push('modal/popup closed');

        var result = 'Clicked ' + tag + ': ' + t;
        if (effects.length > 0) result += ' [' + effects.join(', ') + ']';
        return {ok: result};
    })"""

    if index is not None:
        # Click by data-exec-idx
        js = CLICK_JS + """(document.querySelector('[data-exec-idx="%d"]') || null)""" % index
        null_msg = "Element #%d not found. DOM may have changed — run browser_read_elements again." % index

    elif text:
        escaped = text.replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ")
        js = """(function() {
            var target = '%s'.toLowerCase();
            var sels = 'button, a, input[type="submit"], input[type="button"], [role="button"], [role="option"], [role="radio"], [role="checkbox"], label, [onclick], [tabindex="0"]';
            var all = document.querySelectorAll(sels);
            // Try exact match first, then partial
            var candidates = [];
            for (var i = 0; i < all.length; i++) {
                var el = all[i];
                var elText = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().toLowerCase();
                if (elText === target) return %s(el);
                if (elText.indexOf(target) !== -1) candidates.push(el);
            }
            if (candidates.length > 0) return %s(candidates[0]);
            return null;
        })()""" % (escaped, CLICK_JS, CLICK_JS)
        null_msg = "No interactive element contains text: '%s'" % text

    elif selector:
        # Use Playwright's built-in click for CSS selectors (handles waits better)
        try:
            url_before = await page.evaluate("window.location.href")
            await page.click(selector, timeout=5000)
            url_after = await page.evaluate("window.location.href")
            effects = ""
            if url_after != url_before:
                effects = f" [page navigated to {url_after}]"
            return {"content": [{"type": "text", "text": f"Clicked '{selector}'.{effects}"}], "isError": False}
        except Exception as e:
            err = str(e)
            if "timeout" in err.lower():
                return {"content": [{"type": "text", "text": f"Timeout waiting for '{selector}'. Element may not exist or is hidden."}], "isError": True}
            return {"content": [{"type": "text", "text": f"Click failed on '{selector}': {e}"}], "isError": True}

    else:
        return {"content": [{"type": "text", "text": "Provide one of: index, text, or selector."}], "isError": True}

    # Execute JS-based click (for index and text modes)
    try:
        result = await page.evaluate(js)
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Click error: {e}"}], "isError": True}

    if result is None:
        return {"content": [{"type": "text", "text": null_msg}], "isError": True}
    if isinstance(result, dict):
        if "error" in result:
            return {"content": [{"type": "text", "text": result["error"]}], "isError": True}
        if "ok" in result:
            # Brief wait for DOM to settle after click
            if wait_ms > 0:
                await asyncio.sleep(wait_ms / 1000.0)
            return {"content": [{"type": "text", "text": result["ok"]}], "isError": False}

    return {"content": [{"type": "text", "text": str(result)}], "isError": False}


async def handle_type_element(params: dict) -> dict:
    """Type text with React compat, input validation, contenteditable support, and verification."""
    page = await _get_pw_page()
    text = params.get("text", "")
    index = params.get("index")
    selector = params.get("selector")
    clear_first = params.get("clear_first", True)
    press_enter = params.get("press_enter", False)

    if not text and not press_enter:
        return {"content": [{"type": "text", "text": "No text provided."}], "isError": True}

    escaped = text.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")

    # Build element finder
    if index is not None:
        find_el = 'document.querySelector(\'[data-exec-idx="%d"]\')' % index
    elif selector:
        sel = selector.replace("'", "\\'")
        find_el = "document.querySelector('%s')" % sel
    else:
        find_el = ("document.activeElement && "
                   "(document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA' || document.activeElement.getAttribute('contenteditable') === 'true') "
                   "? document.activeElement "
                   ": document.querySelector('input:not([type=hidden]):not([type=submit]):not([type=button]), textarea, [contenteditable=\"true\"]')")

    clear_js = "true" if clear_first else "false"
    enter_js = "true" if press_enter else "false"

    js = """(function() {
        var el = %s;
        if (!el) return {error: 'No input field found. Use browser_read_elements to find inputs.'};

        // Check state
        if (el.disabled || el.getAttribute('aria-disabled') === 'true')
            return {error: 'Input is DISABLED.'};
        if (el.readOnly) return {error: 'Input is READONLY.'};

        var tag = el.tagName.toLowerCase();
        var isContentEditable = el.getAttribute('contenteditable') === 'true';

        el.scrollIntoView({block: 'center', behavior: 'instant'});
        el.focus();

        var inputText = '%s';
        var doClear = %s;
        var doEnter = %s;

        if (isContentEditable) {
            // ContentEditable (rich text editors, MathJax, etc.)
            if (doClear) el.innerHTML = '';
            el.focus();
            document.execCommand('insertText', false, inputText);
        } else {
            // Standard input/textarea — React-compatible native setter
            if (doClear) {
                var nsClear = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
                           || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
                if (nsClear && nsClear.set) nsClear.set.call(el, '');
                else el.value = '';
                el.dispatchEvent(new Event('input', {bubbles: true}));
            }
            var newVal = doClear ? inputText : el.value + inputText;
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
                            || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
            if (nativeSetter && nativeSetter.set) {
                nativeSetter.set.call(el, newVal);
            } else {
                el.value = newVal;
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            // Also dispatch KeyboardEvent for apps that listen to keystrokes
            for (var c = 0; c < Math.min(inputText.length, 3); c++) {
                el.dispatchEvent(new KeyboardEvent('keydown', {key: inputText[c], bubbles: true}));
                el.dispatchEvent(new KeyboardEvent('keyup', {key: inputText[c], bubbles: true}));
            }
        }

        // Optional Enter key
        if (doEnter) {
            el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
            el.dispatchEvent(new KeyboardEvent('keyup', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
        }

        // Verify
        var actualVal = isContentEditable ? el.innerText.trim() : el.value;
        var inputType = el.type || 'text';
        var msg = 'Typed "' + inputText.substring(0, 40) + '" into ' + tag + '[type=' + inputType + ']';
        if (actualVal !== newVal && !isContentEditable) {
            msg += ' (WARNING: field shows "' + actualVal.substring(0, 30) + '" — may have validation)';
        }
        return {ok: msg};
    })()""" % (find_el, escaped, clear_js, enter_js)

    try:
        result = await page.evaluate(js)
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Type error: {e}"}], "isError": True}

    if isinstance(result, dict):
        if "error" in result:
            return {"content": [{"type": "text", "text": result["error"]}], "isError": True}
        if "ok" in result:
            return {"content": [{"type": "text", "text": result["ok"]}], "isError": False}

    return {"content": [{"type": "text", "text": str(result)}], "isError": False}


async def handle_page_state(params: dict) -> dict:
    """Comprehensive page diagnostics — URL, loading state, modals, errors, form state."""
    page = await _get_pw_page()

    js = """(function() {
        var state = {};
        state.url = window.location.href;
        state.title = document.title;
        state.readyState = document.readyState;

        // Loading indicators
        var loaders = document.querySelectorAll('[aria-busy="true"], .loading, .spinner, [class*="load"]');
        state.loading = loaders.length > 0;

        // Open modals/dialogs
        var modals = document.querySelectorAll('[role="dialog"], [role="alertdialog"], .modal.show, .modal[open], dialog[open]');
        state.modals = [];
        for (var m = 0; m < modals.length; m++) {
            state.modals.push((modals[m].innerText || '').trim().substring(0, 200));
        }

        // Error messages (common patterns)
        var errors = document.querySelectorAll('[class*="error"], [class*="Error"], [role="alert"], .alert-danger, .validation-error');
        state.errors = [];
        for (var e = 0; e < errors.length && e < 5; e++) {
            var t = (errors[e].innerText || '').trim();
            if (t.length > 0 && t.length < 200) state.errors.push(t);
        }

        // Form state (all visible inputs with values)
        var inputs = document.querySelectorAll('input:not([type=hidden]), textarea, select');
        state.formFields = [];
        for (var i = 0; i < inputs.length && i < 20; i++) {
            var inp = inputs[i];
            var rect = inp.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) continue;
            state.formFields.push({
                tag: inp.tagName.toLowerCase(),
                type: inp.type || '',
                name: inp.name || inp.id || '',
                value: (inp.value || '').substring(0, 50),
                checked: inp.checked || false,
                disabled: inp.disabled || false,
            });
        }

        // Console errors (if we have access)
        state.jsErrors = [];

        // Iframe count
        state.iframeCount = document.querySelectorAll('iframe').length;

        return JSON.stringify(state);
    })()"""

    try:
        raw = await page.evaluate(js)
        data = json.loads(raw) if isinstance(raw, str) else raw

        lines = []
        lines.append(f"URL: {data.get('url', '?')}")
        lines.append(f"Title: {data.get('title', '?')}")
        lines.append(f"Ready: {data.get('readyState', '?')} | Loading: {data.get('loading', False)} | Iframes: {data.get('iframeCount', 0)}")

        if data.get("modals"):
            lines.append(f"\nOpen modals ({len(data['modals'])}):")
            for m in data["modals"]:
                lines.append(f"  - {m[:100]}")

        if data.get("errors"):
            lines.append(f"\nError messages ({len(data['errors'])}):")
            for e in data["errors"]:
                lines.append(f"  ! {e}")

        if data.get("formFields"):
            lines.append(f"\nForm fields ({len(data['formFields'])}):")
            for f in data["formFields"]:
                status = []
                if f.get("checked"): status.append("checked")
                if f.get("disabled"): status.append("DISABLED")
                st = f" [{','.join(status)}]" if status else ""
                lines.append(f"  {f['name'] or '(unnamed)'} [{f['type']}] = \"{f['value']}\"{st}")

        return {"content": [{"type": "text", "text": "\n".join(lines)}], "isError": False}

    except Exception as e:
        return {"content": [{"type": "text", "text": f"Page state error: {e}"}], "isError": True}


async def handle_wait_for(params: dict) -> dict:
    """Wait for an element or condition before proceeding."""
    page = await _get_pw_page()
    css_selector = params.get("selector", "")
    text_content = params.get("text", "")
    timeout_ms = params.get("timeout", 5000)
    wait_hidden = params.get("wait_hidden", False)

    if not css_selector and not text_content:
        return {"content": [{"type": "text", "text": "Provide 'selector' or 'text' to wait for."}], "isError": True}

    try:
        if css_selector:
            if wait_hidden:
                await page.wait_for_selector(css_selector, state="hidden", timeout=timeout_ms)
                return {"content": [{"type": "text", "text": f"'{css_selector}' is now hidden/gone."}], "isError": False}
            else:
                await page.wait_for_selector(css_selector, state="visible", timeout=timeout_ms)
                return {"content": [{"type": "text", "text": f"'{css_selector}' is now visible."}], "isError": False}

        elif text_content:
            escaped = text_content.replace("'", "\\'")
            # Poll for text appearance
            end_time = asyncio.get_event_loop().time() + timeout_ms / 1000.0
            while asyncio.get_event_loop().time() < end_time:
                found = await page.evaluate(
                    "document.body.innerText.toLowerCase().includes('%s'.toLowerCase())" % escaped
                )
                if found and not wait_hidden:
                    return {"content": [{"type": "text", "text": f"Text '{text_content}' found on page."}], "isError": False}
                if not found and wait_hidden:
                    return {"content": [{"type": "text", "text": f"Text '{text_content}' is gone."}], "isError": False}
                await asyncio.sleep(0.3)

            if wait_hidden:
                return {"content": [{"type": "text", "text": f"Timeout: text '{text_content}' still present after {timeout_ms}ms."}], "isError": True}
            return {"content": [{"type": "text", "text": f"Timeout: text '{text_content}' not found after {timeout_ms}ms."}], "isError": True}

    except Exception as e:
        err = str(e)
        if "timeout" in err.lower():
            what = css_selector or text_content
            return {"content": [{"type": "text", "text": f"Timeout after {timeout_ms}ms waiting for: {what}"}], "isError": True}
        return {"content": [{"type": "text", "text": f"Wait error: {e}"}], "isError": True}


async def handle_select_tab(params: dict) -> dict:
    """Switch to a different Chrome tab by index or URL pattern."""
    global _cdp_page
    if not _cdp_connected or not _cdp_browser:
        return {"content": [{"type": "text", "text": "Not connected to Chrome via CDP."}], "isError": True}

    tab_index = params.get("tab_index")
    url_pattern = params.get("url_pattern", "")

    all_pages = []
    for context in _cdp_browser.contexts:
        all_pages.extend(context.pages)

    if tab_index is not None:
        if 0 <= tab_index < len(all_pages):
            _cdp_page = all_pages[tab_index]
            title = await _cdp_page.title()
            return {"content": [{"type": "text", "text": f"Switched to tab [{tab_index}]: {_cdp_page.url} — {title}"}], "isError": False}
        return {"content": [{"type": "text", "text": f"Tab index {tab_index} out of range (0-{len(all_pages)-1})."}], "isError": True}

    if url_pattern:
        for i, p in enumerate(all_pages):
            if url_pattern.lower() in p.url.lower():
                _cdp_page = p
                title = await _cdp_page.title()
                return {"content": [{"type": "text", "text": f"Switched to tab [{i}]: {_cdp_page.url} — {title}"}], "isError": False}
        return {"content": [{"type": "text", "text": f"No tab contains '{url_pattern}' in URL."}], "isError": True}

    return {"content": [{"type": "text", "text": "Provide tab_index or url_pattern."}], "isError": True}


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
    "browser_page_state": handle_page_state,
    "browser_wait_for": handle_wait_for,
    "browser_select_tab": handle_select_tab,
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

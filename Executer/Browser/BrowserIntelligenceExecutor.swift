import Foundation

// MARK: - Browser Intelligence Tools (Stage 5)
// Deep browser control via Playwright: DOM reading, JS execution, console, element interaction.

struct BrowserExecuteJSTool: ToolDefinition {
    let name = "browser_execute_js"
    let description = "Execute JavaScript in the current browser tab and return the result. Use for reading page data, manipulating DOM, or running custom logic."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "code": JSONSchema.string(description: "JavaScript code to execute"),
            "timeout_ms": JSONSchema.integer(description: "Execution timeout in milliseconds (default 5000)"),
        ], required: ["code"])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_execute_js", arguments: arguments)
    }
}

struct BrowserReadDOMTool: ToolDefinition {
    let name = "browser_read_dom"
    let description = "Read the DOM tree of the current page or a specific element. Returns tag names, IDs, classes, text content, and attributes in a structured tree."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "selector": JSONSchema.string(description: "CSS selector for the root element (default 'body')"),
            "max_depth": JSONSchema.integer(description: "Maximum depth to traverse (default 5)"),
            "include_text": JSONSchema.boolean(description: "Include text content of elements (default true)"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_read_dom", arguments: arguments)
    }
}

struct BrowserGetConsoleTool: ToolDefinition {
    let name = "browser_get_console"
    let description = "Get recent console log messages from the browser. Useful for debugging JavaScript errors."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "level": JSONSchema.string(description: "Filter by level: 'all' (default), 'error', 'warn', 'log'"),
            "limit": JSONSchema.integer(description: "Maximum messages to return (default 50)"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_get_console", arguments: arguments)
    }
}

struct BrowserInspectElementTool: ToolDefinition {
    let name = "browser_inspect_element"
    let description = "Inspect a specific DOM element by CSS selector. Returns tag, text, value, bounding box, computed styles."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "selector": JSONSchema.string(description: "CSS selector for the element to inspect"),
        ], required: ["selector"])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_inspect_element", arguments: arguments)
    }
}

struct BrowserClickElementCSSTool: ToolDefinition {
    let name = "browser_click_element_css"
    let description = "Click a DOM element by CSS selector. More precise than coordinate clicking — works even if the element position changes."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "selector": JSONSchema.string(description: "CSS selector of the element to click"),
        ], required: ["selector"])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_click_element_css", arguments: arguments)
    }
}

struct BrowserTypeInElementTool: ToolDefinition {
    let name = "browser_type_in_element"
    let description = "Type text into a DOM element by CSS selector. Can clear existing text first (default) or append."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "selector": JSONSchema.string(description: "CSS selector of the input element"),
            "text": JSONSchema.string(description: "Text to type into the element"),
            "clear_first": JSONSchema.boolean(description: "Clear existing text before typing (default true)"),
        ], required: ["selector", "text"])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_type_in_element", arguments: arguments)
    }
}

struct BrowserInterceptNetworkTool: ToolDefinition {
    let name = "browser_intercept_network"
    let description = "Start/stop network request monitoring. Captures URLs, status codes, and methods. Sensitive headers (cookies, auth) are automatically redacted."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.string(description: "'start' to begin capturing, 'stop' to end, 'get_log' to retrieve entries"),
        ], required: ["action"])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_intercept_network", arguments: arguments)
    }
}

struct BrowserNavigateTool: ToolDefinition {
    let name = "browser_navigate"
    let description = "Navigate the browser to a URL. Use this to open a website before reading its DOM."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "The URL to navigate to"),
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_navigate", arguments: arguments)
    }
}

// MARK: - Chrome CDP Connection Tools
// Connect to the user's real Chrome browser via Chrome DevTools Protocol.
// Once connected, ALL browser_* tools operate on the real browser.

struct BrowserConnectChromeTool: ToolDefinition {
    let name = "browser_connect_chrome"
    let description = """
        Connect to the user's real Chrome browser via CDP (Chrome DevTools Protocol). \
        Once connected, all browser tools (read_dom, click, type) operate on the real Chrome tabs. \
        Chrome must be running with --remote-debugging-port=9222. \
        Use url_pattern to select a specific tab (e.g., 'ixl.com').
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "cdp_url": JSONSchema.string(description: "CDP endpoint URL (default http://localhost:9222)"),
            "url_pattern": JSONSchema.string(description: "Select the tab whose URL contains this pattern (e.g., 'ixl.com')"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_connect_chrome", arguments: arguments)
    }
}

struct BrowserReadElementsTool: ToolDefinition {
    let name = "browser_read_elements"
    let description = """
        Read all interactive elements (buttons, inputs, links, selectable options) from the current page's DOM. \
        Returns elements with their text, tag, type, and a unique index. Use the index with browser_click_element or browser_type_element. \
        Much more reliable than accessibility tree for React/dynamic web apps.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "scope": JSONSchema.string(description: "CSS selector to limit scope (e.g., '.question-area', 'main'). Default 'body'."),
        ])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_read_elements", arguments: arguments)
    }
}

struct BrowserClickElementTool: ToolDefinition {
    let name = "browser_click_element"
    let description = """
        Click an element in the browser by its index (from browser_read_elements), \
        by visible text content, or by CSS selector. Works on React/dynamic web apps.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "index": JSONSchema.integer(description: "Element index from browser_read_elements (preferred, most reliable)"),
            "text": JSONSchema.string(description: "Click the first visible interactive element containing this text"),
            "selector": JSONSchema.string(description: "CSS selector (e.g., 'button.submit')"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_click_element", arguments: arguments)
    }
}

struct BrowserTypeElementTool: ToolDefinition {
    let name = "browser_type_element"
    let description = """
        Type text into an input field in the browser. Targets by index (from browser_read_elements), \
        CSS selector, or the currently focused input. Handles React inputs correctly with native setter. \
        Supports contenteditable divs (rich text editors). Verifies the text was accepted.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "The text to type into the field"),
            "index": JSONSchema.integer(description: "Element index from browser_read_elements"),
            "selector": JSONSchema.string(description: "CSS selector for the input field"),
            "clear_first": JSONSchema.boolean(description: "Clear existing content before typing (default true)"),
            "press_enter": JSONSchema.boolean(description: "Press Enter after typing (for search fields, chat inputs)"),
        ], required: ["text"])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_type_element", arguments: arguments)
    }
}

// MARK: - Debug & Diagnostic Tools

struct BrowserPageStateTool: ToolDefinition {
    let name = "browser_page_state"
    let description = """
        Get comprehensive page diagnostics: URL, title, loading state, open modals/dialogs, \
        error messages, all form field values, and iframe count. Use this to debug when actions \
        seem to fail or to verify the page state after an action.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_page_state", arguments: arguments)
    }
}

struct BrowserWaitForTool: ToolDefinition {
    let name = "browser_wait_for"
    let description = """
        Wait for an element to appear/disappear or for text to show on the page. \
        Use after clicking submit to wait for the result, or to wait for a loading spinner to disappear.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "selector": JSONSchema.string(description: "CSS selector to wait for (e.g., '.result', 'button.next')"),
            "text": JSONSchema.string(description: "Text content to wait for on the page"),
            "timeout": JSONSchema.integer(description: "Max wait time in milliseconds (default 5000)"),
            "wait_hidden": JSONSchema.boolean(description: "Wait for element/text to DISAPPEAR instead of appear"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_wait_for", arguments: arguments)
    }
}

struct BrowserSelectTabTool: ToolDefinition {
    let name = "browser_select_tab"
    let description = "Switch to a different Chrome tab by index or URL pattern. Use to navigate between tabs when connected via CDP."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "tab_index": JSONSchema.integer(description: "Tab index (from browser_connect_chrome output)"),
            "url_pattern": JSONSchema.string(description: "Switch to tab whose URL contains this text"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        try await BrowserService.shared.callBridgeTool(name: "browser_select_tab", arguments: arguments)
    }
}

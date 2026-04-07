import Foundation

// MARK: - Browser Task (multi-step web automation)

struct BrowserTaskTool: ToolDefinition {
    let name = "browser_task"
    let description = """
        Execute a multi-step browser task using AI-powered automation. The browser agent can navigate pages, \
        click buttons, fill forms, log in, extract data, and complete complex web workflows. \
        Use this for interactive web tasks like booking, shopping, form submission, or multi-page navigation. \
        For INTERACTIVE web tasks only (clicking, form-filling, multi-page navigation). For simple URL reading, use read_web_page or fetch_url_content.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "task": JSONSchema.string(description: "Natural language description of the web task to perform (e.g., 'Go to amazon.com and search for wireless headphones under $50')"),
            "url": JSONSchema.string(description: "Starting URL to navigate to before executing the task (optional — the agent can navigate on its own)"),
            "visible": JSONSchema.boolean(description: "Show the browser window so the user can watch (default: false/headless). Set true for tasks that need user oversight like payments."),
            "max_steps": JSONSchema.integer(description: "Maximum browser actions before stopping (default 20)", minimum: 1, maximum: 50),
        ], required: ["task"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let task = try requiredString("task", from: args)
        let url = optionalString("url", from: args)
        let visible = optionalBool("visible", from: args)
        let maxSteps = optionalInt("max_steps", from: args)

        let result = try await BrowserService.shared.executeTask(
            task: task,
            url: url,
            visible: visible,
            maxSteps: maxSteps
        )

        // Store trail for UI display (independent of LLM response)
        if !result.trail.isEmpty {
            await MainActor.run {
                BrowserTrailStore.shared.currentTrail = result.trail
            }
        }

        // Build text result for the LLM (includes trail so it can reference sites)
        var output = result.text
        if !result.trail.isEmpty {
            output += "\n\n[Sites visited]\n"
            for entry in result.trail {
                let label = entry.summary.isEmpty ? entry.title : entry.summary
                output += "- \(entry.url) — \(label)\n"
            }
        }
        if result.steps > 0 {
            output += "\n[Completed in \(result.steps) browser steps]"
        }
        return output
    }
}

// MARK: - Browser Extract (data extraction)

struct BrowserExtractTool: ToolDefinition {
    let name = "browser_extract"
    let description = """
        Extract structured data from a web page using a real browser (handles JavaScript-rendered content). \
        Unlike fetch_url_content which only gets static HTML, this renders the page fully before extracting. \
        Use for dynamic sites, SPAs, or when you need specific elements via CSS selectors.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "The URL to extract data from"),
            "instruction": JSONSchema.string(description: "What data to extract (e.g., 'Extract all product names and prices')"),
            "selector": JSONSchema.string(description: "CSS selector to target specific elements (e.g., '.product-card', '#results')"),
            "max_length": JSONSchema.integer(description: "Maximum characters to return (default 10000)", minimum: 100, maximum: 50000),
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = try requiredString("url", from: args)
        let instruction = optionalString("instruction", from: args)
        let selector = optionalString("selector", from: args)

        return try await BrowserService.shared.extractData(
            url: url,
            instruction: instruction,
            selector: selector
        )
    }
}

// MARK: - Browser Session Management

struct BrowserSessionTool: ToolDefinition {
    let name = "browser_session"
    let description = "Manage the browser session: list open tabs, close tabs, toggle between headless and visible mode, or close the browser entirely."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(description: "Session action to perform", values: ["list_tabs", "close_tab", "toggle_visible", "close_all"]),
            "tab_index": JSONSchema.integer(description: "Tab index to act on (for close_tab action)", minimum: 0),
        ], required: ["action"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)
        let tabIndex = optionalInt("tab_index", from: args)

        return try await BrowserService.shared.manageSession(
            action: action,
            tabIndex: tabIndex
        )
    }
}

// MARK: - Browser Screenshot

struct BrowserScreenshotTool: ToolDefinition {
    let name = "browser_screenshot"
    let description = "Capture a screenshot of the browser's current view. Returns the file path of the saved screenshot. Useful for debugging or inspecting what the browser agent sees."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let path = try await BrowserService.shared.screenshot()
        return "Screenshot saved to: \(path)"
    }
}

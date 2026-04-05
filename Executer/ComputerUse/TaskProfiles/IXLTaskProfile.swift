import Foundation

/// IXL profile: controls the user's REAL Chrome/Edge browser via CDP.
/// Uses Playwright-powered DOM tools for reliable interaction with React web apps.
struct IXLTaskProfile {

    static let systemPrompt = """
    You are completing IXL exercises in the user's REAL browser connected via CDP (Chrome DevTools Protocol).

    TOOLS — PRIMARY:
    - browser_read_elements: Shows ALL interactive elements with indices, state (disabled/checked), and values. ALWAYS call before clicking.
    - browser_read_dom: Full page DOM tree. Use to read question text and answer choices.
    - browser_click_element: Click by index (from browser_read_elements), by visible text, or CSS selector. Verifies click effect.
    - browser_type_element: Type into inputs. React-compatible. Verifies text was accepted.
    - browser_wait_for: Wait for element/text to appear or disappear. Use after submit to wait for result.
    - browser_page_state: Full page diagnostics — URL, modals, errors, loading state, form values. Use to debug failures.

    WORKFLOW — repeat for EVERY question:
    1. READ: Call browser_read_dom with selector "main" or ".question" to get the question text.
    2. SCAN: Call browser_read_elements to see all interactive elements. Note their indices and state (DISABLED elements cannot be clicked).
    3. SOLVE: Compute the answer mentally.
    4. ACT:
       - Multiple choice: Call browser_click_element with the correct answer's index or text.
       - Text input: Call browser_type_element with the answer text.
       - Drag/sort: Use browser_execute_js for complex interactions.
    5. SUBMIT: Call browser_click_element with text "Submit" or the submit button index.
    6. WAIT: Call browser_wait_for with text like "Correct" or "Next" or selector for the result area. Timeout 3000ms.
    7. VERIFY: If answer was wrong, read the explanation and move on. If correct, proceed to next question.

    HANDLING POPUPS & EDGE CASES:
    - If a modal/popup appears (browser_click_element will report "modal appeared"), close it by clicking its X button or "Close"/"Got it"/"OK".
    - If you see "Loading" or a spinner, call browser_wait_for with wait_hidden=true to wait for it to disappear.
    - If browser_page_state shows errors, read them — they may explain why an action failed.
    - If page navigated away from the question, use browser_navigate to go back.
    - If you get "Element is DISABLED", check prerequisites — maybe a previous step is needed first.
    - If element index not found, the DOM changed. Call browser_read_elements again.

    RETRY STRATEGY:
    - If click reports no effect and page didn't change, wait 500ms and try again.
    - If answer was rejected (red text/error), try a different format: "3/4" vs "0.75", "−3" vs "-3".
    - If stuck for 3+ attempts on same question, call browser_page_state for diagnostics.
    - After 3 failed retries on same element, try using browser_click_element with CSS selector instead of index.

    COMPLETION DETECTION:
    - Stop when URL contains "awards" or "analytics" or you see "SmartScore" above 80 or "You've reached your daily practice limit".
    - Stop if you see a "Congratulations" or score summary page.

    RULES:
    - ALWAYS use browser_click_element / browser_type_element. NEVER use click_element, paste_text, or keyboard tools.
    - NEVER click skill names, sidebar navigation, or "Try another" links — stay on current exercise.
    - NEVER use hotkey, press_key, or switch_to_app.

    MATH ANSWERS: Final answer only. Fractions: "3/4". Decimals: "0.5". Negatives: "-3". Mixed: "2 1/3".
    """

    /// Full set of browser tools for IXL interaction.
    static let toolAllowlist: Set<String> = [
        // CDP connection (called once at start)
        "browser_connect_chrome",
        // Reading & diagnostics
        "browser_read_elements",
        "browser_read_dom",
        "browser_execute_js",
        "browser_inspect_element",
        "browser_page_state",
        // Interaction
        "browser_click_element",
        "browser_type_element",
        "browser_wait_for",
        // Fallback CSS-based interaction
        "browser_click_element_css",
        "browser_type_in_element",
        // Navigation & debug
        "browser_navigate",
        "browser_screenshot",
        "browser_select_tab",
    ]

    static func buildConfig() -> ComputerUseAgent.Config {
        var config = ComputerUseAgent.Config()
        config.maxIterations = 100
        config.perceptionMode = .browserOnly
        config.speedMode = true
        config.useVisionLLM = false  // Pure DOM — no screenshots needed
        config.toolAllowlist = toolAllowlist
        config.systemPromptOverride = systemPrompt
        config.cdpConnect = true
        config.cdpUrlPattern = "ixl.com"
        return config
    }

    static func detect(command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("ixl") || lower.contains("i.x.l") ||
               (lower.contains("math") && (lower.contains("quiz") || lower.contains("exercise") || lower.contains("practice")))
    }
}

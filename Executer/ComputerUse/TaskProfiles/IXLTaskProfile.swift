import Foundation

/// IXL profile: works in the user's REAL browser (Safari/Chrome) that's already open.
/// Uses screen reading + mouse + keyboard to interact with the actual browser window.
/// The headless Playwright browser is NOT used here.
struct IXLTaskProfile {

    static let systemPrompt = """
    You are completing IXL exercises in the user's REAL Chrome browser connected via CDP.

    TOOLS — USE IN ORDER:
    - browser_read_elements: Shows ALL clickable elements (buttons, inputs, links) from the real DOM with indices.
    - browser_read_dom: Returns full page DOM tree. Use to read question text and answer choices.
    - browser_click_element: Click by index (from browser_read_elements), by visible text, or CSS selector.
    - browser_type_element: Type into input fields. Handles React inputs correctly with native setter.
    - browser_execute_js: Run JavaScript for complex page interaction.

    WORKFLOW — repeat for EVERY question:
    1. READ: Call browser_read_dom to get the question text.
    2. SCAN: Call browser_read_elements to see all interactive elements and their indices.
    3. SOLVE: Compute the answer.
    4. ACT:
       - Multiple choice: Call browser_click_element with the correct answer's index or text.
       - Text input: Call browser_type_element with the answer text.
    5. SUBMIT: Call browser_click_element with text "Submit" or the submit button index.
    6. VERIFY: Call browser_read_dom to confirm and read the next question.

    CRITICAL RULES:
    - ALWAYS call browser_read_elements before clicking. It assigns element indices.
    - Use browser_click_element (by index or text), NOT click_element. click_element uses AX tree which fails on React web apps.
    - Use browser_type_element, NOT paste_text, for web inputs. It triggers React's onChange correctly.
    - If a click fails, call browser_read_elements again — the DOM may have updated after the action.
    - NEVER click navigation links, sidebar items, skill names, or anything that leaves the current question.
    - NEVER use hotkey or press_key. NEVER switch apps.
    - Keep count. Stop when you see a score/completion page.

    MATH ANSWERS: Final answer only. Fractions: "3/4". Decimals: "0.5". Negatives: "-3"
    """

    /// Browser CDP tools for reliable DOM interaction.
    static let toolAllowlist: Set<String> = [
        // CDP connection (called once at start by ComputerUseAgent)
        "browser_connect_chrome",
        // DOM reading
        "browser_read_elements",
        "browser_read_dom",
        "browser_execute_js",
        "browser_inspect_element",
        // Interaction (index-based — preferred)
        "browser_click_element",
        "browser_type_element",
        // CSS-based interaction (fallback)
        "browser_click_element_css",
        "browser_type_in_element",
        // Navigation & screenshot (for error recovery)
        "browser_navigate",
        "browser_screenshot",
    ]

    static func buildConfig() -> ComputerUseAgent.Config {
        var config = ComputerUseAgent.Config()
        config.maxIterations = 100
        config.perceptionMode = .browserOnly
        config.speedMode = true
        config.useVisionLLM = false  // No screenshots — pure DOM
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

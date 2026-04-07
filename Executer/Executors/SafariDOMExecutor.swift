import Foundation

/// Executes JavaScript in the current Safari tab and returns the result.
func safariJS(_ js: String) throws -> String {
    let escaped = js
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let script = """
    tell application "Safari"
        if (count of windows) = 0 then return "ERR:No Safari windows open."
        if (count of tabs of front window) = 0 then return "ERR:No tabs open."
        set jsResult to do JavaScript "\(escaped)" in current tab of front window
        return jsResult
    end tell
    """
    return try AppleScriptRunner.runThrowing(script)
}

// MARK: - Safari Read Interactive Elements

struct SafariReadElementsTool: ToolDefinition {
    let name = "safari_read_elements"
    let description = """
        Read all interactive elements (buttons, inputs, links, selectable options) from the current Safari page's REAL DOM. \
        Much more reliable than AX tree for React/dynamic web apps. Returns elements with their text, tag, type, \
        and a unique index you can pass to safari_click or safari_type.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "scope": JSONSchema.string(description: "CSS selector to limit scope (e.g., '.question-area', 'main'). Omit for full page."),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let scope = optionalString("scope", from: args)

        let scopeSelector = scope.map { "document.querySelector('\($0.replacingOccurrences(of: "'", with: "\\'"))')" } ?? "document.body"

        let js = """
        (function() {
            var root = \(scopeSelector);
            if (!root) return 'ERR:Scope not found';
            var els = root.querySelectorAll('button, input, select, textarea, a[href], [role="button"], [role="option"], [role="menuitem"], [role="radio"], [role="checkbox"], [role="link"], [onclick], [tabindex="0"], label[for]');
            var results = [];
            for (var i = 0; i < els.length && i < 80; i++) {
                var el = els[i];
                var rect = el.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) continue;
                if (rect.bottom < 0 || rect.top > window.innerHeight) continue;
                var text = (el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || el.title || '').trim().substring(0, 100);
                var tag = el.tagName.toLowerCase();
                var type = el.type || el.getAttribute('role') || '';
                var cls = (el.className && typeof el.className === 'string') ? el.className.split(' ').slice(0, 3).join(' ') : '';
                el.setAttribute('data-exec-idx', i);
                results.push(i + '|' + tag + '|' + type + '|' + text + '|' + Math.round(rect.left) + ',' + Math.round(rect.top) + ',' + Math.round(rect.width) + 'x' + Math.round(rect.height));
            }
            return results.join('\\n');
        })()
        """

        let raw = try safariJS(js)
        if raw.hasPrefix("ERR:") { return String(raw.dropFirst(4)) }
        if raw.isEmpty { return "No interactive elements found on page." }

        let lines = raw.split(separator: "\n")
        var output = ["Interactive elements (\(lines.count)):"]
        output.append("idx | tag    | type   | text                    | position")
        output.append("--- | ------ | ------ | ----------------------- | --------")
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 4).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5 else { continue }
            let idx = parts[0].padding(toLength: 3, withPad: " ", startingAt: 0)
            let tag = parts[1].padding(toLength: 6, withPad: " ", startingAt: 0)
            let type = String(parts[2].prefix(6)).padding(toLength: 6, withPad: " ", startingAt: 0)
            let text = String(parts[3].prefix(23)).padding(toLength: 23, withPad: " ", startingAt: 0)
            output.append("\(idx) | \(tag) | \(type) | \(text) | \(parts[4])")
        }
        return output.joined(separator: "\n")
    }
}

// MARK: - Safari Click Element

struct SafariClickTool: ToolDefinition {
    let name = "safari_click"
    let description = """
        Click an element in the current Safari page by its index (from safari_read_elements), \
        by CSS selector, or by visible text content. Works on React/dynamic web apps where click_element fails. \
        This clicks in the REAL DOM, not the accessibility tree.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "index": JSONSchema.integer(description: "Element index from safari_read_elements (preferred, most reliable)"),
            "selector": JSONSchema.string(description: "CSS selector (e.g., 'button.submit', 'input[type=radio]')"),
            "text": JSONSchema.string(description: "Click the first visible interactive element containing this text"),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let index = optionalInt("index", from: args)
        let selector = optionalString("selector", from: args)
        let text = optionalString("text", from: args)

        let js: String

        if let index = index {
            // Click by data-exec-idx (set during safari_read_elements)
            js = """
            (function() {
                var el = document.querySelector('[data-exec-idx="\(index)"]');
                if (!el) return 'ERR:Element #\(index) not found. Run safari_read_elements again.';
                el.scrollIntoView({block: 'center'});
                el.focus();
                el.click();
                var tag = el.tagName.toLowerCase();
                var text = (el.innerText || el.value || '').trim().substring(0, 60);
                return 'Clicked ' + tag + ': ' + text;
            })()
            """
        } else if let selector = selector {
            let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
            js = """
            (function() {
                var el = document.querySelector('\(escaped)');
                if (!el) return 'ERR:No element matches selector: \(escaped)';
                el.scrollIntoView({block: 'center'});
                el.focus();
                el.click();
                var text = (el.innerText || el.value || '').trim().substring(0, 60);
                return 'Clicked: ' + text;
            })()
            """
        } else if let text = text {
            let escaped = text.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")
            js = """
            (function() {
                var target = '\(escaped)'.toLowerCase();
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
                return 'ERR:No visible interactive element contains text: ' + target;
            })()
            """
        } else {
            return "Provide one of: index (from safari_read_elements), selector (CSS), or text."
        }

        let result = try safariJS(js)
        if result.hasPrefix("ERR:") { return String(result.dropFirst(4)) }
        return result
    }
}

// MARK: - Safari Type In Element

struct SafariTypeTool: ToolDefinition {
    let name = "safari_type"
    let description = """
        Type text into an input field in the current Safari page. Targets by index (from safari_read_elements), \
        CSS selector, or finds the currently focused/first visible input. Clears the field first, then types. \
        Works on React/dynamic inputs where AX-based typing fails.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "The text to enter into the field"),
            "index": JSONSchema.integer(description: "Element index from safari_read_elements"),
            "selector": JSONSchema.string(description: "CSS selector for the input field"),
            "clear_first": JSONSchema.boolean(description: "Clear existing content before typing (default true)"),
        ], required: ["text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = try requiredString("text", from: args)
        let index = optionalInt("index", from: args)
        let selector = optionalString("selector", from: args)
        let clearFirst = (args["clear_first"] as? Bool) ?? true

        let escaped = text.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")

        let findElement: String
        if let index = index {
            findElement = "document.querySelector('[data-exec-idx=\"\(index)\"]')"
        } else if let selector = selector {
            let sel = selector.replacingOccurrences(of: "'", with: "\\'")
            findElement = "document.querySelector('\(sel)')"
        } else {
            findElement = "document.activeElement && (document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA') ? document.activeElement : document.querySelector('input:not([type=hidden]):not([type=submit]):not([type=button]), textarea')"
        }

        let js = """
        (function() {
            var el = \(findElement);
            if (!el) return 'ERR:No input field found. Use safari_read_elements to find available inputs.';
            el.scrollIntoView({block: 'center'});
            el.focus();
            \(clearFirst ? "el.value = '';" : "")
            // Use native setter to trigger React's onChange
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value') || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
            if (nativeSetter && nativeSetter.set) {
                nativeSetter.set.call(el, \(clearFirst ? "" : "el.value + ") '\(escaped)');
            } else {
                el.value = \(clearFirst ? "" : "el.value + ") '\(escaped)';
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return 'Typed "' + '\(escaped)'.substring(0, 40) + '" into ' + el.tagName.toLowerCase() + (el.placeholder ? ' (' + el.placeholder + ')' : '');
        })()
        """

        let result = try safariJS(js)
        if result.hasPrefix("ERR:") { return String(result.dropFirst(4)) }
        return result
    }
}

// MARK: - Safari Select Option

struct SafariSelectTool: ToolDefinition {
    let name = "safari_select"
    let description = "Select an option from a dropdown (<select>) element in Safari by its visible text or value."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "option_text": JSONSchema.string(description: "The visible text of the option to select"),
            "index": JSONSchema.integer(description: "Element index of the <select> from safari_read_elements"),
            "selector": JSONSchema.string(description: "CSS selector for the <select> element"),
        ], required: ["option_text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let optionText = try requiredString("option_text", from: args)
        let index = optionalInt("index", from: args)
        let selector = optionalString("selector", from: args)

        let escaped = optionText.replacingOccurrences(of: "'", with: "\\'")

        let findElement: String
        if let index = index {
            findElement = "document.querySelector('[data-exec-idx=\"\(index)\"]')"
        } else if let selector = selector {
            let sel = selector.replacingOccurrences(of: "'", with: "\\'")
            findElement = "document.querySelector('\(sel)')"
        } else {
            findElement = "document.querySelector('select')"
        }

        let js = """
        (function() {
            var el = \(findElement);
            if (!el || el.tagName !== 'SELECT') return 'ERR:No <select> found.';
            var opts = el.options;
            for (var i = 0; i < opts.length; i++) {
                if (opts[i].text.trim().toLowerCase().indexOf('\(escaped)'.toLowerCase()) !== -1) {
                    el.value = opts[i].value;
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return 'Selected: ' + opts[i].text.trim();
                }
            }
            return 'ERR:Option "' + '\(escaped)' + '" not found. Options: ' + Array.from(opts).map(function(o){return o.text.trim()}).join(', ');
        })()
        """

        let result = try safariJS(js)
        if result.hasPrefix("ERR:") { return String(result.dropFirst(4)) }
        return result
    }
}

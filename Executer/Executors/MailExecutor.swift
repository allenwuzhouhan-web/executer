import Foundation
import AppKit

/// Checks that Mail.app is running or launches it, returning an error string if unavailable.
func ensureMailAvailable() -> String? {
    let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
    if !running {
        // Try to launch Mail.app
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false  // Don't steal focus
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        if let mailURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
            NSWorkspace.shared.openApplication(at: mailURL, configuration: config) { _, error in
                launchError = error
                semaphore.signal()
            }
            semaphore.wait()
        }
        if launchError != nil {
            return "Mail.app is not running and could not be launched. Please open Mail.app first."
        }
        // Give Mail.app a moment to start
        Thread.sleep(forTimeInterval: 1.5)
    }
    return nil
}

// MARK: - Search Mail

struct SearchMailTool: ToolDefinition {
    let name = "search_mail"
    let description = "Search emails in macOS Mail.app by sender, subject, or content. Returns matching messages with sender, subject, date, and a preview. All searching happens locally — no data leaves the machine."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search query — matches against sender name, sender address, subject, and message content"),
            "sender": JSONSchema.string(description: "Optional: filter to emails from this sender name or address"),
            "mailbox": JSONSchema.string(description: "Optional: mailbox/folder to search (e.g., 'INBOX', 'Sent'). Defaults to all mailboxes."),
            "limit": JSONSchema.integer(description: "Max results to return (default 10, max 25)"),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        if let err = ensureMailAvailable() { return err }
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let sender = optionalString("sender", from: args)
        let mailbox = optionalString("mailbox", from: args)
        let limit = min(optionalInt("limit", from: args) ?? 10, 25)

        let escapedQuery = AppleScriptRunner.escape(query)

        // Build the search scope
        var searchScope: String
        if let mailbox = mailbox {
            let escapedMailbox = AppleScriptRunner.escape(mailbox)
            searchScope = """
            set searchScope to {}
            repeat with acct in accounts
                try
                    set mb to mailbox "\(escapedMailbox)" of acct
                    set end of searchScope to mb
                end try
            end repeat
            if (count of searchScope) = 0 then
                error "Mailbox '\(escapedMailbox)' not found in any account."
            end if
            """
        } else {
            // Search inbox of all accounts
            searchScope = """
            set searchScope to {}
            repeat with acct in accounts
                try
                    set end of searchScope to inbox of acct
                end try
            end repeat
            """
        }

        // Build sender filter condition
        let senderFilter: String
        if let sender = sender {
            let escapedSender = AppleScriptRunner.escape(sender).lowercased()
            senderFilter = """
            set senderAddr to sender of msg
            set senderName to extract name from senderAddr
            set senderEmail to extract address from senderAddr
            if senderName is not missing value then
                set senderName to senderName as text
            else
                set senderName to ""
            end if
            if senderEmail is not missing value then
                set senderEmail to senderEmail as text
            else
                set senderEmail to ""
            end if
            set senderMatch to false
            considering case
                if senderName contains "\(escapedSender)" or senderEmail contains "\(escapedSender)" then
                    set senderMatch to true
                end if
            end considering
            if not senderMatch then
                set skipMsg to true
            end if
            """
        } else {
            senderFilter = ""
        }

        let script = """
        tell application "Mail"
            \(searchScope)

            set resultList to {}
            set hitCount to 0

            repeat with mb in searchScope
                try
                    set msgs to (messages of mb whose subject contains "\(escapedQuery)" or content contains "\(escapedQuery)")
                    repeat with msg in msgs
                        if hitCount ≥ \(limit) then exit repeat

                        set skipMsg to false
                        \(senderFilter)

                        if not skipMsg then
                            set msgId to id of msg
                            set msgSubject to subject of msg
                            set msgDate to date received of msg
                            set msgSender to sender of msg
                            set msgRead to read status of msg
                            set msgSnippet to text 1 thru (min of {200, length of (content of msg)}) of (content of msg)

                            set readFlag to "unread"
                            if msgRead then set readFlag to "read"

                            set entry to ("ID:" & msgId & "|||SUBJECT:" & msgSubject & "|||FROM:" & msgSender & "|||DATE:" & (msgDate as text) & "|||STATUS:" & readFlag & "|||PREVIEW:" & msgSnippet)
                            set end of resultList to entry
                            set hitCount to hitCount + 1
                        end if
                    end repeat
                    if hitCount ≥ \(limit) then exit repeat
                end try
            end repeat

            if (count of resultList) = 0 then
                return "NO_RESULTS"
            end if

            set AppleScript's text item delimiters to "<<<SEP>>>"
            return resultList as text
        end tell
        """

        let raw = try AppleScriptRunner.runThrowing(script)

        if raw == "NO_RESULTS" {
            var desc = "No emails found matching \"\(query)\""
            if let sender = sender { desc += " from \(sender)" }
            return desc + "."
        }

        let entries = raw.components(separatedBy: "<<<SEP>>>")
        var results: [String] = []

        for entry in entries {
            let parts = entry.components(separatedBy: "|||")
            var fields: [String: String] = [:]
            for part in parts {
                if let colonIndex = part.firstIndex(of: ":") {
                    let key = String(part[part.startIndex..<colonIndex])
                    let value = String(part[part.index(after: colonIndex)...])
                    fields[key] = value
                }
            }

            let id = fields["ID"] ?? "?"
            let subject = fields["SUBJECT"] ?? "(no subject)"
            let from = fields["FROM"] ?? "?"
            let date = fields["DATE"] ?? "?"
            let status = fields["STATUS"] ?? "?"
            let preview = fields["PREVIEW"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(120) ?? ""

            results.append("""
            [\(status)] \(subject)
              From: \(from)
              Date: \(date)
              Preview: \(preview)...
              [mail_id: \(id)]
            """)
        }

        return "Found \(results.count) email(s):\n\n" + results.joined(separator: "\n\n")
    }
}

// MARK: - Open Email in Window

struct OpenEmailTool: ToolDefinition {
    let name = "open_email"
    let description = "Open a specific email in its own message window (like double-clicking it in Mail.app). Use the mail_id from search_mail results."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "mail_id": JSONSchema.string(description: "The message ID from search_mail results (the numeric ID after 'mail_id:')"),
        ], required: ["mail_id"])
    }

    func execute(arguments: String) async throws -> String {
        if let err = ensureMailAvailable() { return err }
        let args = try parseArguments(arguments)
        let mailId = try requiredString("mail_id", from: args)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let script = """
        tell application "Mail"
            set targetMsg to missing value
            repeat with acct in accounts
                repeat with mb in mailboxes of acct
                    try
                        set targetMsg to (first message of mb whose id is \(mailId))
                        exit repeat
                    end try
                end repeat
                if targetMsg is not missing value then exit repeat
            end repeat

            if targetMsg is missing value then
                -- Also check inbox directly (faster path)
                repeat with acct in accounts
                    try
                        set targetMsg to (first message of inbox of acct whose id is \(mailId))
                        exit repeat
                    end try
                end repeat
            end if

            if targetMsg is missing value then
                return "NOT_FOUND"
            end if

            open targetMsg
            activate
            return "OPENED"
        end tell
        """

        let result = try AppleScriptRunner.runThrowing(script)

        if result == "NOT_FOUND" {
            return "Could not find email with ID \(mailId). It may have been moved or deleted."
        }

        return "Opened email in its own window."
    }
}

// MARK: - Read Email Content

struct ReadEmailTool: ToolDefinition {
    let name = "read_email"
    let description = "Read the full content of a specific email by its mail_id. Returns the complete email body text without opening a window."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "mail_id": JSONSchema.string(description: "The message ID from search_mail results"),
        ], required: ["mail_id"])
    }

    func execute(arguments: String) async throws -> String {
        if let err = ensureMailAvailable() { return err }
        let args = try parseArguments(arguments)
        let mailId = try requiredString("mail_id", from: args)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let script = """
        tell application "Mail"
            set targetMsg to missing value
            repeat with acct in accounts
                try
                    set targetMsg to (first message of inbox of acct whose id is \(mailId))
                    exit repeat
                end try
            end repeat

            if targetMsg is missing value then
                repeat with acct in accounts
                    repeat with mb in mailboxes of acct
                        try
                            set targetMsg to (first message of mb whose id is \(mailId))
                            exit repeat
                        end try
                    end repeat
                    if targetMsg is not missing value then exit repeat
                end repeat
            end if

            if targetMsg is missing value then
                return "NOT_FOUND"
            end if

            set msgSubject to subject of targetMsg
            set msgSender to sender of targetMsg
            set msgDate to date received of targetMsg
            set msgContent to content of targetMsg
            set msgTo to ""
            try
                set recipList to to recipients of targetMsg
                set AppleScript's text item delimiters to ", "
                set toNames to {}
                repeat with r in recipList
                    set end of toNames to (address of r as text)
                end repeat
                set msgTo to toNames as text
            end try

            return ("SUBJECT:" & msgSubject & "|||FROM:" & msgSender & "|||TO:" & msgTo & "|||DATE:" & (msgDate as text) & "|||BODY:" & msgContent)
        end tell
        """

        let raw = try AppleScriptRunner.runThrowing(script)

        if raw == "NOT_FOUND" {
            return "Could not find email with ID \(mailId)."
        }

        let parts = raw.components(separatedBy: "|||")
        var fields: [String: String] = [:]
        for part in parts {
            if let colonIndex = part.firstIndex(of: ":") {
                let key = String(part[part.startIndex..<colonIndex])
                let value = String(part[part.index(after: colonIndex)...])
                fields[key] = value
            }
        }

        let subject = fields["SUBJECT"] ?? "(no subject)"
        let from = fields["FROM"] ?? "?"
        let to = fields["TO"] ?? "?"
        let date = fields["DATE"] ?? "?"
        let body = fields["BODY"] ?? "(empty)"

        // Truncate very long emails
        let maxLength = 8000
        let truncatedBody = body.count > maxLength
            ? String(body.prefix(maxLength)) + "\n\n... (truncated — \(body.count) characters total)"
            : body

        return """
        Subject: \(subject)
        From: \(from)
        To: \(to)
        Date: \(date)

        \(truncatedBody)
        """
    }
}

// MARK: - List Mailboxes

struct ListMailboxesTool: ToolDefinition {
    let name = "list_mailboxes"
    let description = "List all mailboxes/folders available in Mail.app across all accounts."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        if let err = ensureMailAvailable() { return err }
        let script = """
        tell application "Mail"
            set result to {}
            repeat with acct in accounts
                set acctName to name of acct
                set mbs to mailboxes of acct
                repeat with mb in mbs
                    set end of result to (acctName & " / " & name of mb)
                end repeat
            end repeat
            set AppleScript's text item delimiters to "\\n"
            return result as text
        end tell
        """

        let result = try AppleScriptRunner.runThrowing(script)
        if result.isEmpty {
            return "No mailboxes found. Is Mail.app set up with an account?"
        }
        return "Mailboxes:\n" + result
    }
}

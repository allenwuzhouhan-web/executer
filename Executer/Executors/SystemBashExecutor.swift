import Foundation

// MARK: - Safe Bash Tools
// Scoped, read-only (or low-risk) shell tools that replace common run_shell_command patterns.
// These are faster (SmartRouter-eligible), safer (no arbitrary execution), and filter better (intent classification).

// MARK: Network Info

struct GetNetworkInfoTool: ToolDefinition {
    let name = "get_network_info"
    let description = "Get network information: IP addresses (local & public), Wi-Fi SSID, active interface, DNS servers, and gateway"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let command = """
        echo "=LOCAL_IP="; ipconfig getifaddr en0 2>/dev/null || echo "Not connected"; \
        echo "=PUBLIC_IP="; curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "Unavailable"; \
        echo "=WIFI="; networksetup -getairportnetwork en0 2>/dev/null; \
        echo "=GATEWAY="; netstat -rn 2>/dev/null | grep '^default' | head -1 | awk '{print $2}'; \
        echo "=DNS="; scutil --dns 2>/dev/null | grep 'nameserver' | head -3 | awk '{print $3}'; \
        echo "=INTERFACE="; route -n get default 2>/dev/null | grep 'interface' | awk '{print $2}'
        """
        let result = try ShellRunner.run(command, timeout: 8)
        let out = result.output

        var lines: [String] = ["Network Information:"]

        if let s = extractSection(out, start: "=LOCAL_IP=", end: "=PUBLIC_IP=") {
            lines.append("- Local IP: \(s)")
        }
        if let s = extractSection(out, start: "=PUBLIC_IP=", end: "=WIFI=") {
            lines.append("- Public IP: \(s)")
        }
        if let s = extractSection(out, start: "=WIFI=", end: "=GATEWAY=") {
            let ssid = s.replacingOccurrences(of: "Current Wi-Fi Network: ", with: "")
            lines.append("- Wi-Fi: \(ssid)")
        }
        if let s = extractSection(out, start: "=GATEWAY=", end: "=DNS="), !s.isEmpty {
            lines.append("- Gateway: \(s)")
        }
        if let s = extractSection(out, start: "=DNS=", end: "=INTERFACE="), !s.isEmpty {
            let servers = s.components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: ", ")
            lines.append("- DNS: \(servers)")
        }
        if let s = extractSection(out, start: "=INTERFACE=", end: nil), !s.isEmpty {
            lines.append("- Interface: \(s)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: Disk Usage

struct GetDiskUsageTool: ToolDefinition {
    let name = "get_disk_usage"
    let description = "Get disk usage for all mounted volumes, or a specific path. Shows total, used, available, and capacity percentage."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Optional path to check (defaults to all volumes)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = optionalString("path", from: args) ?? "/"
        let result = try ShellRunner.run("df -h \(path.shellEscaped()) 2>/dev/null", timeout: 5)
        if result.exitCode != 0 {
            return "Failed to get disk usage: \(result.output)"
        }

        let lines = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return "No disk information available." }

        var output = ["Disk Usage:"]
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 8).map(String.init)
            if parts.count >= 5 {
                let fs = parts[0]
                let total = parts[1]
                let used = parts[2]
                let avail = parts[3]
                let pct = parts[4]
                let mount = parts.count >= 9 ? parts[8] : (parts.count >= 6 ? (parts.last ?? "") : "")
                output.append("- \(mount.isEmpty ? fs : mount): \(used) used / \(total) total (\(pct)), \(avail) available")
            }
        }
        return output.joined(separator: "\n")
    }
}

// MARK: Process List

struct ListProcessesTool: ToolDefinition {
    let name = "list_processes"
    let description = "List running processes sorted by CPU or memory usage. Shows PID, name, CPU%, and memory%."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "sort_by": JSONSchema.enumString(description: "Sort by 'cpu' or 'memory' (default: cpu)", values: ["cpu", "memory"]),
            "limit": JSONSchema.integer(description: "Number of processes to show (default: 15)", minimum: 1, maximum: 50)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let sortBy = optionalString("sort_by", from: args) ?? "cpu"
        let limit = optionalInt("limit", from: args) ?? 15

        let sortFlag = sortBy == "memory" ? "-m" : "-o cpu"
        let result = try ShellRunner.run("ps aux \(sortFlag) | head -\(limit + 1)", timeout: 5)
        if result.exitCode != 0 { return "Failed to list processes." }

        let lines = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return "No processes found." }

        var output = ["Top \(limit) processes by \(sortBy):"]
        output.append(String(format: "%-8s %-6s %-6s %@", "PID", "CPU%", "MEM%", "COMMAND"))

        for line in lines.dropFirst().prefix(limit) {
            let parts = line.split(separator: " ", maxSplits: 10).map(String.init)
            if parts.count >= 11 {
                let pid = parts[1]
                let cpu = parts[2]
                let mem = parts[3]
                let cmd = URL(fileURLWithPath: parts[10]).lastPathComponent
                output.append(String(format: "%-8s %-6s %-6s %@", pid, cpu, mem, cmd))
            }
        }
        return output.joined(separator: "\n")
    }
}

// MARK: Check Port

struct CheckPortTool: ToolDefinition {
    let name = "check_port"
    let description = "Check if a network port is in use, and which process is using it. Useful for dev workflows."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "port": JSONSchema.integer(description: "The port number to check", minimum: 1, maximum: 65535)
        ], required: ["port"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let port = optionalInt("port", from: args) ?? 0
        guard port > 0 else { throw ExecuterError.invalidArguments("Port number required") }

        let result = try ShellRunner.run("lsof -i :\(port) -P -n 2>/dev/null", timeout: 5)

        if result.output.isEmpty {
            return "Port \(port) is free — nothing is listening on it."
        }

        let lines = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var output = ["Port \(port) is in use:"]
        for line in lines.dropFirst().prefix(5) {
            let parts = line.split(separator: " ", maxSplits: 9).map(String.init)
            if parts.count >= 2 {
                let cmd = parts[0]
                let pid = parts[1]
                let state = parts.last ?? ""
                output.append("- \(cmd) (PID \(pid)) — \(state)")
            }
        }
        return output.joined(separator: "\n")
    }
}

// MARK: Git Status

struct GitStatusTool: ToolDefinition {
    let name = "git_status"
    let description = "Get git repository status: branch, uncommitted changes, recent commits, and remote tracking info."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Path to the git repository (defaults to current directory)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = optionalString("path", from: args)
        let cd = path != nil ? "cd \(path!.shellEscaped()) && " : ""

        let command = """
        \(cd)echo "=BRANCH="; git branch --show-current 2>/dev/null; \
        echo "=STATUS="; git status --porcelain 2>/dev/null | head -20; \
        echo "=LOG="; git log --oneline -5 2>/dev/null; \
        echo "=REMOTE="; git remote -v 2>/dev/null | head -2; \
        echo "=STASH="; git stash list 2>/dev/null | head -3
        """
        let result = try ShellRunner.run(command, timeout: 10)

        if result.exitCode != 0 && result.output.contains("not a git repository") {
            return "Not a git repository\(path != nil ? " at \(path!)" : "")."
        }

        let out = result.output
        var lines: [String] = []

        if let branch = extractSection(out, start: "=BRANCH=", end: "=STATUS="), !branch.isEmpty {
            lines.append("Branch: \(branch)")
        }

        if let status = extractSection(out, start: "=STATUS=", end: "=LOG=") {
            let changes = status.components(separatedBy: "\n").filter { !$0.isEmpty }
            if changes.isEmpty {
                lines.append("Working tree: clean")
            } else {
                lines.append("Changes (\(changes.count)):")
                for change in changes.prefix(15) {
                    lines.append("  \(change)")
                }
                if changes.count > 15 { lines.append("  ... and \(changes.count - 15) more") }
            }
        }

        if let log = extractSection(out, start: "=LOG=", end: "=REMOTE="), !log.isEmpty {
            lines.append("Recent commits:")
            for commit in log.components(separatedBy: "\n").filter({ !$0.isEmpty }).prefix(5) {
                lines.append("  \(commit)")
            }
        }

        if let remote = extractSection(out, start: "=REMOTE=", end: "=STASH="), !remote.isEmpty {
            let first = remote.components(separatedBy: "\n").first ?? remote
            lines.append("Remote: \(first)")
        }

        if let stash = extractSection(out, start: "=STASH=", end: nil), !stash.isEmpty {
            let stashes = stash.components(separatedBy: "\n").filter { !$0.isEmpty }
            lines.append("Stashes: \(stashes.count)")
        }

        return lines.isEmpty ? "No git info available." : lines.joined(separator: "\n")
    }
}

// MARK: Count Lines

struct CountLinesTool: ToolDefinition {
    let name = "count_lines"
    let description = "Count lines of code in a directory, grouped by file extension. Excludes common non-code directories."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Directory to count (defaults to current directory)"),
            "extension": JSONSchema.string(description: "Only count files with this extension (e.g., 'swift', 'py')")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = optionalString("path", from: args) ?? "."
        let ext = optionalString("extension", from: args)

        let excludes = "--exclude-dir={.git,node_modules,build,.build,venv,.venv,__pycache__,Pods,.next,dist}"

        // Use find + wc to count lines per file, then aggregate by extension
        let command = """
        find \(path.shellEscaped()) \(excludes) -type f \(ext != nil ? "-name '*.\(ext!)'" : "") | \
        while read f; do ext="${f##*.}"; wc -l < "$f" | tr -d ' '; echo " $ext"; done 2>/dev/null | \
        awk '{sum[$2]+=$1; total+=$1; count[$2]++} END{for(e in sum) printf "%s: %d lines (%d files)\\n", e, sum[e], count[e]; printf "\\nTotal: %d lines\\n", total}' | \
        sort -t: -k2 -rn
        """
        let result = try ShellRunner.run(command, timeout: 15)
        if result.output.isEmpty { return "No code files found in \(path)." }
        return "Lines of Code:\n\(result.output)"
    }
}

// MARK: Compress Files

struct CompressFilesTool: ToolDefinition {
    let name = "compress_files"
    let description = "Compress files or directories into a zip or tar.gz archive."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "source": JSONSchema.string(description: "File or directory to compress"),
            "destination": JSONSchema.string(description: "Output archive path (e.g., ~/Desktop/backup.zip)"),
            "format": JSONSchema.enumString(description: "Archive format (default: zip)", values: ["zip", "tar.gz"])
        ], required: ["source"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let source = try requiredString("source", from: args)
        let format = optionalString("format", from: args) ?? "zip"

        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        let defaultDest = format == "zip" ? "\(sourceName).zip" : "\(sourceName).tar.gz"
        let destination = optionalString("destination", from: args) ?? defaultDest

        let command: String
        if format == "tar.gz" {
            command = "tar -czf \(destination.shellEscaped()) \(source.shellEscaped()) 2>&1"
        } else {
            command = "zip -r \(destination.shellEscaped()) \(source.shellEscaped()) 2>&1"
        }

        let result = try ShellRunner.run(command, timeout: 60)
        if result.exitCode != 0 {
            return "Compression failed: \(result.output)"
        }

        // Get size of output
        let sizeResult = try ShellRunner.run("ls -lh \(destination.shellEscaped()) | awk '{print $5}'", timeout: 3)
        let size = sizeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        return "Compressed \(source) → \(destination) (\(size))"
    }
}

// MARK: Environment Info

struct GetEnvInfoTool: ToolDefinition {
    let name = "get_env_info"
    let description = "Get development environment info: installed runtimes (Python, Node, Ruby, Go, Rust, Java), package managers (brew, pip, npm), and shell."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let command = """
        echo "=SHELL="; echo $SHELL; \
        echo "=PYTHON="; python3 --version 2>/dev/null || echo "not installed"; \
        echo "=NODE="; node --version 2>/dev/null || echo "not installed"; \
        echo "=RUBY="; ruby --version 2>/dev/null | head -1 || echo "not installed"; \
        echo "=GO="; go version 2>/dev/null || echo "not installed"; \
        echo "=RUST="; rustc --version 2>/dev/null || echo "not installed"; \
        echo "=JAVA="; java --version 2>&1 | head -1 || echo "not installed"; \
        echo "=SWIFT="; swift --version 2>/dev/null | head -1 || echo "not installed"; \
        echo "=BREW="; brew --version 2>/dev/null | head -1 || echo "not installed"; \
        echo "=GIT="; git --version 2>/dev/null; \
        echo "=DOCKER="; docker --version 2>/dev/null || echo "not installed"; \
        echo "=END="
        """
        let result = try ShellRunner.run(command, timeout: 10)
        let out = result.output

        var lines = ["Development Environment:"]
        let checks: [(label: String, start: String, end: String)] = [
            ("Shell", "=SHELL=", "=PYTHON="),
            ("Python", "=PYTHON=", "=NODE="),
            ("Node.js", "=NODE=", "=RUBY="),
            ("Ruby", "=RUBY=", "=GO="),
            ("Go", "=GO=", "=RUST="),
            ("Rust", "=RUST=", "=JAVA="),
            ("Java", "=JAVA=", "=SWIFT="),
            ("Swift", "=SWIFT=", "=BREW="),
            ("Homebrew", "=BREW=", "=GIT="),
            ("Git", "=GIT=", "=DOCKER="),
            ("Docker", "=DOCKER=", "=END="),
        ]

        for check in checks {
            if let val = extractSection(out, start: check.start, end: check.end), !val.isEmpty {
                let clean = val.components(separatedBy: "\n").first ?? val
                lines.append("- \(check.label): \(clean)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: Kill Process

struct KillProcessTool: ToolDefinition {
    let name = "kill_process"
    let description = "Kill a process by PID or name. Use list_processes first to find the target."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "pid": JSONSchema.integer(description: "Process ID to kill"),
            "name": JSONSchema.string(description: "Process name to kill (uses killall)"),
            "force": JSONSchema.boolean(description: "Force kill with SIGKILL instead of SIGTERM (default: false)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let pid = optionalInt("pid", from: args)
        let name = optionalString("name", from: args)
        let force = optionalBool("force", from: args) ?? false

        guard pid != nil || name != nil else {
            throw ExecuterError.invalidArguments("Provide either 'pid' or 'name'")
        }

        let signal = force ? "-9" : "-15"
        let command: String
        if let pid = pid {
            command = "kill \(signal) \(pid) 2>&1"
        } else {
            command = "killall \(signal) \(name!.shellEscaped()) 2>&1"
        }

        let result = try ShellRunner.run(command, timeout: 5)
        if result.exitCode == 0 {
            return "Killed \(pid != nil ? "PID \(pid!)" : name!) successfully."
        }
        return "Failed to kill process: \(result.output)"
    }
}

// MARK: Ping Host

struct PingHostTool: ToolDefinition {
    let name = "ping_host"
    let description = "Ping a host to check connectivity and latency. Sends 3 packets by default."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "host": JSONSchema.string(description: "Hostname or IP to ping (e.g., google.com, 8.8.8.8)"),
            "count": JSONSchema.integer(description: "Number of packets (default: 3)", minimum: 1, maximum: 10)
        ], required: ["host"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let host = try requiredString("host", from: args)
        let count = optionalInt("count", from: args) ?? 3

        // Validate host — no shell injection
        let safeHost = host.replacingOccurrences(of: "[^a-zA-Z0-9.\\-:]", with: "", options: .regularExpression)
        let result = try ShellRunner.run("ping -c \(count) -W 3000 \(safeHost) 2>&1", timeout: TimeInterval(count * 4 + 2))

        if result.exitCode != 0 {
            return "Ping to \(safeHost) failed — host unreachable or DNS resolution failed."
        }

        // Extract summary line
        let lines = result.output.components(separatedBy: "\n")
        var output = ["Ping \(safeHost):"]
        for line in lines {
            if line.contains("packets transmitted") || line.contains("round-trip") || line.contains("avg") {
                output.append("  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return output.count > 1 ? output.joined(separator: "\n") : "Ping to \(safeHost) succeeded."
    }
}

// MARK: Who Is Using (find what's using a resource)

struct WhatsUsingTool: ToolDefinition {
    let name = "whats_using"
    let description = "Find what process is using a file, directory, or port. Useful for debugging 'resource busy' or 'address in use' errors."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "resource": JSONSchema.string(description: "File path, directory, or port number to check")
        ], required: ["resource"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let resource = try requiredString("resource", from: args)

        let command: String
        if let port = Int(resource), port > 0, port <= 65535 {
            command = "lsof -i :\(port) -P -n 2>/dev/null"
        } else {
            command = "lsof \(resource.shellEscaped()) 2>/dev/null"
        }

        let result = try ShellRunner.run(command, timeout: 5)
        if result.output.isEmpty {
            return "Nothing is currently using \(resource)."
        }

        let lines = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var output = ["Processes using \(resource):"]
        for line in lines.prefix(11) {
            output.append("  \(line)")
        }
        if lines.count > 11 { output.append("  ... and \(lines.count - 11) more") }
        return output.joined(separator: "\n")
    }
}

// MARK: Speed Test (download speed estimate)

struct QuickSpeedTestTool: ToolDefinition {
    let name = "quick_speed_test"
    let description = "Quick download speed estimate by fetching a small test file. Not a full speed test but gives a rough idea."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let result = try ShellRunner.run(
            "curl -s -o /dev/null -w '%{speed_download} %{time_total}' --max-time 5 https://speed.cloudflare.com/__down?bytes=1000000 2>&1",
            timeout: 10
        )
        let parts = result.output.split(separator: " ")
        if parts.count >= 2, let bytesPerSec = Double(parts[0]), let time = Double(parts[1]) {
            let mbps = (bytesPerSec * 8) / 1_000_000
            return String(format: "Download speed: ~%.1f Mbps (1MB test, %.1fs)", mbps, time)
        }
        return "Speed test failed — check your internet connection."
    }
}

// MARK: - Download File

struct DownloadFileTool: ToolDefinition {
    let name = "download_file"
    let description = "Download a file from a URL to a local path. Supports HTTP/HTTPS. Shows progress and final size."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "URL to download from"),
            "destination": JSONSchema.string(description: "Local path to save to (defaults to ~/Downloads/<filename>)")
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = try requiredString("url", from: args)
        let filename = URL(string: url)?.lastPathComponent ?? "download"
        let dest = optionalString("destination", from: args) ?? "~/Downloads/\(filename)"
        let expandedDest = (dest as NSString).expandingTildeInPath

        let result = try ShellRunner.run(
            "curl -fSL --max-time 120 --create-dirs -o \(expandedDest.shellEscaped()) \(url.shellEscaped()) 2>&1",
            timeout: 130
        )
        if result.exitCode != 0 {
            return "Download failed: \(result.output)"
        }
        let sizeResult = try ShellRunner.run("ls -lh \(expandedDest.shellEscaped()) | awk '{print $5}'", timeout: 3)
        return "Downloaded → \(expandedDest) (\(sizeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }
}

// MARK: - Extract Archive

struct ExtractArchiveTool: ToolDefinition {
    let name = "extract_archive"
    let description = "Extract a zip, tar.gz, tar.bz2, or tar.xz archive to a directory."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "archive": JSONSchema.string(description: "Path to the archive file"),
            "destination": JSONSchema.string(description: "Directory to extract into (defaults to same directory as archive)")
        ], required: ["archive"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let archive = try requiredString("archive", from: args)
        let dest = optionalString("destination", from: args)
            ?? URL(fileURLWithPath: archive).deletingLastPathComponent().path

        let lower = archive.lowercased()
        let command: String
        if lower.hasSuffix(".zip") {
            command = "unzip -o \(archive.shellEscaped()) -d \(dest.shellEscaped()) 2>&1"
        } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            command = "tar -xzf \(archive.shellEscaped()) -C \(dest.shellEscaped()) 2>&1"
        } else if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") {
            command = "tar -xjf \(archive.shellEscaped()) -C \(dest.shellEscaped()) 2>&1"
        } else if lower.hasSuffix(".tar.xz") {
            command = "tar -xJf \(archive.shellEscaped()) -C \(dest.shellEscaped()) 2>&1"
        } else if lower.hasSuffix(".tar") {
            command = "tar -xf \(archive.shellEscaped()) -C \(dest.shellEscaped()) 2>&1"
        } else {
            return "Unsupported archive format. Supported: .zip, .tar.gz, .tgz, .tar.bz2, .tar.xz, .tar"
        }

        let result = try ShellRunner.run(command, timeout: 60)
        if result.exitCode != 0 {
            return "Extraction failed: \(result.output)"
        }
        return "Extracted \(archive) → \(dest)"
    }
}

// MARK: - HTTP Request

struct HttpRequestTool: ToolDefinition {
    let name = "http_request"
    let description = "Make an HTTP request (GET, POST, PUT, PATCH). Returns status code, headers, and body. Great for testing APIs."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "The URL to request"),
            "method": JSONSchema.enumString(description: "HTTP method (default: GET)", values: ["GET", "POST", "PUT", "PATCH", "HEAD", "OPTIONS"]),
            "headers": JSONSchema.string(description: "Headers as JSON object, e.g. {\"Authorization\": \"Bearer xxx\"}"),
            "body": JSONSchema.string(description: "Request body (for POST/PUT/PATCH)"),
            "content_type": JSONSchema.string(description: "Content-Type header shorthand (e.g. 'json', 'form')")
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = try requiredString("url", from: args)
        let method = optionalString("method", from: args) ?? "GET"
        let body = optionalString("body", from: args)
        let contentType = optionalString("content_type", from: args)
        let headersJSON = optionalString("headers", from: args)

        var curlParts = ["curl -s -w '\\n=HTTP_CODE=%{http_code}' -X \(method)"]

        // Content type shorthand
        if let ct = contentType {
            switch ct.lowercased() {
            case "json": curlParts.append("-H 'Content-Type: application/json'")
            case "form": curlParts.append("-H 'Content-Type: application/x-www-form-urlencoded'")
            case "xml": curlParts.append("-H 'Content-Type: application/xml'")
            default: curlParts.append("-H 'Content-Type: \(ct)'")
            }
        }

        // Custom headers
        if let hJSON = headersJSON,
           let hData = hJSON.data(using: .utf8),
           let hDict = try? JSONSerialization.jsonObject(with: hData) as? [String: String] {
            for (key, value) in hDict {
                curlParts.append("-H '\(key): \(value)'")
            }
        }

        // Body
        if let b = body {
            curlParts.append("-d \(b.shellEscaped())")
        }

        curlParts.append("--max-time 30")
        curlParts.append(url.shellEscaped())

        let command = curlParts.joined(separator: " ") + " 2>&1"
        let result = try ShellRunner.run(command, timeout: 35)

        // Parse status code from output
        let output = result.output
        var statusCode = "???"
        var responseBody = output
        if let codeRange = output.range(of: "=HTTP_CODE=") {
            statusCode = String(output[codeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            responseBody = String(output[..<codeRange.lowerBound])
        }

        // Truncate large responses
        if responseBody.count > 3000 {
            responseBody = String(responseBody.prefix(3000)) + "\n... (truncated, \(responseBody.count) bytes total)"
        }

        return "HTTP \(statusCode) \(method) \(url)\n\(responseBody)"
    }
}

// MARK: - Run Script Inline

struct RunScriptTool: ToolDefinition {
    let name = "run_script"
    let description = """
        Write and execute a script immediately. This is your most powerful tool — use it for ANY task \
        that involves file processing, data manipulation, computation, or automation beyond simple read/write.

        ## Languages
        - **python** (default choice): managed venv with pre-installed packages: \
        PyPDF2, PyMuPDF (fitz — preferred for PDF split/merge/extract), pdfplumber (PDF tables), \
        Pillow, pandas, numpy, matplotlib, openpyxl, requests, beautifulsoup4, lxml, html2text, \
        python-pptx, python-docx, pyyaml, tabulate, Jinja2, chardet. Use `packages` param for extras.
        - **node**: JavaScript/Node.js
        - **ruby**: Ruby scripts
        - **bash**: Shell scripts
        - **cpp**: C++ (compiled with clang++, C++17, then executed)
        - **c**: C (compiled with clang, then executed)
        - **swift**: Swift scripts (interpreted via `swift` command)
        - **go**: Go (compiled with `go build`, then executed)
        - **typescript**: TypeScript via ts-node or tsx (requires installation)

        ## When to use this tool
        - PDF: split by chapter/page, merge, extract text/tables, add watermark, metadata
        - Data: CSV/JSON/XML/YAML transforms, filtering, aggregation, format conversion
        - Files: batch rename, organize by type, find duplicates, bulk convert, dedup
        - Web: scrape pages, parse HTML, extract tables, download series of files
        - Images: resize, crop, convert format, thumbnails, strip EXIF
        - Text: regex across files, log analysis, report generation, search/replace
        - Math: statistics, financial calculations, unit conversion, charting
        - Performance: use cpp/c for compute-heavy tasks (algorithms, number crunching)

        ## Output
        Print results to stdout. For files, print the output path. \
        Print a final summary (e.g. "Created 12 chapter files in ~/Desktop/textbook_chapters/").

        ## File access
        Use working_dir to set where the script runs (default: ~/Desktop). \
        Use absolute paths for input files. Output files go in working_dir by default.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "language": JSONSchema.enumString(description: "Script language", values: ["python", "node", "ruby", "bash", "cpp", "c", "swift", "go", "typescript"]),
            "code": JSONSchema.string(description: "The script code to execute"),
            "timeout": JSONSchema.integer(description: "Timeout in seconds (default: 60, max: 300)", minimum: 1, maximum: 300),
            "working_dir": JSONSchema.string(description: "Working directory for the script. Default: ~/Desktop"),
            "packages": JSONSchema.string(description: "Additional pip packages to install before running (comma-separated). Python only."),
            "args": JSONSchema.string(description: "Command-line arguments to pass to the script (space-separated). Accessed via sys.argv in Python, process.argv in Node."),
        ], required: ["language", "code"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let language = try requiredString("language", from: args)
        let code = try requiredString("code", from: args)
        let timeout = min(optionalInt("timeout", from: args) ?? 60, 300)
        let workingDir = optionalString("working_dir", from: args) ?? "~/Desktop"
        let packagesRaw = optionalString("packages", from: args)
        let scriptArgs = optionalString("args", from: args)?
            .components(separatedBy: " ")
            .filter { !$0.isEmpty } ?? []

        // Resolve working directory
        let expandedDir = NSString(string: workingDir).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        // Python: use managed venv with packages
        if language == "python" {
            return try await executePython(code: code, timeout: timeout, workingDir: expandedDir, packagesRaw: packagesRaw, scriptArgs: scriptArgs)
        }

        // Compiled languages: write source → compile → run binary
        if language == "cpp" || language == "c" {
            return try await executeCompiled(code: code, language: language, timeout: timeout, workingDir: expandedDir)
        }

        // Swift: interpreted via `swift` command
        if language == "swift" {
            return try await executeSwift(code: code, timeout: timeout, workingDir: expandedDir)
        }

        // Go: compile with `go build` then run
        if language == "go" {
            return try await executeGo(code: code, timeout: timeout, workingDir: expandedDir)
        }

        // TypeScript: try tsx, then ts-node, then compile to JS
        if language == "typescript" {
            return try await executeTypeScript(code: code, timeout: timeout, workingDir: expandedDir)
        }

        // Interpreted languages: write to temp file and run
        let ext: String
        let runner: String
        switch language {
        case "node": ext = "js"; runner = Self.findExecutable("node", searchPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"]) ?? "node"
        case "ruby": ext = "rb"; runner = "/usr/bin/ruby"
        case "bash": ext = "sh"; runner = "/bin/bash"
        default: return "Unsupported language: \(language). Supported: python, node, ruby, bash, cpp, c, swift, go, typescript."
        }

        let tempFile = NSTemporaryDirectory() + "executer_script_\(UUID().uuidString.prefix(8)).\(ext)"
        try code.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let result = try await AsyncShellRunner.run(
            executable: runner,
            arguments: [tempFile] + scriptArgs,
            workingDirectory: expandedDir,
            timeout: timeout
        )
        return formatResult(result)
    }

    // MARK: - Compiled Languages (C/C++)

    private func executeCompiled(code: String, language: String, timeout: Int, workingDir: String) async throws -> String {
        let ext = language == "cpp" ? "cpp" : "c"
        let compiler = language == "cpp" ? "clang++" : "clang"
        let stdFlag = language == "cpp" ? "-std=c++17" : "-std=c17"
        let uid = UUID().uuidString.prefix(8)
        let sourceFile = NSTemporaryDirectory() + "executer_\(uid).\(ext)"
        let binaryFile = NSTemporaryDirectory() + "executer_\(uid)_bin"

        try code.write(toFile: sourceFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: sourceFile)
            try? FileManager.default.removeItem(atPath: binaryFile)
        }

        // Find compiler
        guard let compilerPath = Self.findExecutable(compiler, searchPaths: [
            "/usr/bin/\(compiler)", "/opt/homebrew/bin/\(compiler)", "/usr/local/bin/\(compiler)"
        ]) else {
            return "Error: \(compiler) not found. Install Xcode Command Line Tools: xcode-select --install"
        }

        // Compile
        let compileResult = try await AsyncShellRunner.run(
            executable: compilerPath,
            arguments: [stdFlag, "-O2", "-o", binaryFile, sourceFile],
            workingDirectory: workingDir,
            timeout: 30
        )
        if compileResult.exitCode != 0 {
            let errors = compileResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Compilation failed:\n\(errors)"
        }

        // Make executable
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryFile)

        // Run
        let runResult = try await AsyncShellRunner.run(
            executable: binaryFile,
            arguments: [],
            workingDirectory: workingDir,
            timeout: timeout
        )
        return formatResult(runResult)
    }

    // MARK: - Swift (interpreted)

    private func executeSwift(code: String, timeout: Int, workingDir: String) async throws -> String {
        let uid = UUID().uuidString.prefix(8)
        let sourceFile = NSTemporaryDirectory() + "executer_\(uid).swift"
        try code.write(toFile: sourceFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: sourceFile) }

        guard let swiftPath = Self.findExecutable("swift", searchPaths: [
            "/usr/bin/swift", "/opt/homebrew/bin/swift", "/usr/local/bin/swift"
        ]) else {
            return "Error: swift not found. Install Xcode or Xcode Command Line Tools."
        }

        let result = try await AsyncShellRunner.run(
            executable: swiftPath,
            arguments: [sourceFile],
            workingDirectory: workingDir,
            timeout: timeout
        )
        return formatResult(result)
    }

    // MARK: - Go (compile + run)

    private func executeGo(code: String, timeout: Int, workingDir: String) async throws -> String {
        let uid = UUID().uuidString.prefix(8)
        let tempDir = NSTemporaryDirectory() + "executer_go_\(uid)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let sourceFile = tempDir + "/main.go"
        let binaryFile = tempDir + "/main"

        try code.write(toFile: sourceFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        guard let goPath = Self.findExecutable("go", searchPaths: [
            "/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"
        ]) else {
            return "Error: go not found. Install Go: brew install go"
        }

        // Initialize module
        let initResult = try await AsyncShellRunner.run(
            executable: goPath,
            arguments: ["mod", "init", "executer_script"],
            workingDirectory: tempDir,
            timeout: 10
        )
        if initResult.exitCode != 0 {
            return "Go mod init failed:\n\(initResult.stderr)"
        }

        // Resolve external imports if any (go mod tidy downloads dependencies)
        let tidyResult = try await AsyncShellRunner.run(
            executable: goPath,
            arguments: ["mod", "tidy"],
            workingDirectory: tempDir,
            timeout: 30
        )
        // tidy failure is non-fatal for stdlib-only code (go.sum won't exist)
        if tidyResult.exitCode != 0 && code.contains("\"github.com") {
            return "Go mod tidy failed (dependency resolution):\n\(tidyResult.stderr)"
        }

        // Build
        let buildResult = try await AsyncShellRunner.run(
            executable: goPath,
            arguments: ["build", "-o", binaryFile, "."],
            workingDirectory: tempDir,
            timeout: 60
        )
        if buildResult.exitCode != 0 {
            return "Go build failed:\n\(buildResult.stderr)"
        }

        // Run
        let runResult = try await AsyncShellRunner.run(
            executable: binaryFile,
            arguments: [],
            workingDirectory: workingDir,
            timeout: timeout
        )
        return formatResult(runResult)
    }

    // MARK: - TypeScript

    private func executeTypeScript(code: String, timeout: Int, workingDir: String) async throws -> String {
        let uid = UUID().uuidString.prefix(8)
        let sourceFile = NSTemporaryDirectory() + "executer_\(uid).ts"
        try code.write(toFile: sourceFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: sourceFile) }

        // Try tsx first (fastest), then ts-node, then npx tsx
        if let tsxPath = Self.findExecutable("tsx", searchPaths: ["/opt/homebrew/bin/tsx", "/usr/local/bin/tsx"]) {
            let result = try await AsyncShellRunner.run(
                executable: tsxPath,
                arguments: [sourceFile],
                workingDirectory: workingDir,
                timeout: timeout
            )
            return formatResult(result)
        }

        if let tsNodePath = Self.findExecutable("ts-node", searchPaths: ["/opt/homebrew/bin/ts-node", "/usr/local/bin/ts-node"]) {
            let result = try await AsyncShellRunner.run(
                executable: tsNodePath,
                arguments: [sourceFile],
                workingDirectory: workingDir,
                timeout: timeout
            )
            return formatResult(result)
        }

        // Fallback: npx tsx (auto-downloads if needed)
        if let npxPath = Self.findExecutable("npx", searchPaths: ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]) {
            let result = try await AsyncShellRunner.run(
                executable: npxPath,
                arguments: ["tsx", sourceFile],
                workingDirectory: workingDir,
                timeout: timeout
            )
            return formatResult(result)
        }

        return "Error: No TypeScript runner found. Install one: npm install -g tsx"
    }

    // MARK: - Executable Discovery

    private static func findExecutable(_ name: String, searchPaths: [String]) -> String? {
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: `which`
        let result = try? ShellRunner.run("which \(name)", timeout: 5)
        if let result = result, result.exitCode == 0 {
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return nil
    }

    private func executePython(code: String, timeout: Int, workingDir: String, packagesRaw: String?, scriptArgs: [String] = []) async throws -> String {
        let python = PPTExecutor.findPython()

        // Install additional packages if requested
        if let raw = packagesRaw, !raw.isEmpty {
            let packages = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if !packages.isEmpty {
                try? await PPTExecutor.installPackages(packages)
            }
        }

        // Write script to temp file
        let tempFile = NSTemporaryDirectory() + "executer_script_\(UUID().uuidString.prefix(8)).py"
        try code.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let result = try await AsyncShellRunner.run(
            executable: python,
            arguments: [tempFile] + scriptArgs,
            environment: [
                "PYTHONIOENCODING": "utf-8",
                "PYTHONUNBUFFERED": "1",
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
            ],
            workingDirectory: workingDir,
            timeout: timeout
        )
        return formatResult(result)
    }

    private func formatResult(_ result: AsyncShellRunner.Result) -> String {
        if result.timedOut {
            let partial = String(result.stdout.suffix(2000))
            return "Script timed out. Partial output:\n\(partial)"
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        var output = stdout
        if result.exitCode != 0 && !stderr.isEmpty {
            output = output.isEmpty ? stderr : "\(output)\n\(stderr)"
        }

        if output.count > 10000 {
            return "Exit \(result.exitCode):\n\(String(output.prefix(10000)))\n... (\(output.count) chars total, truncated)"
        }
        return result.exitCode == 0 ? output : "Exit \(result.exitCode):\n\(output)"
    }
}

// MARK: - Install Package

struct InstallPackageTool: ToolDefinition {
    let name = "install_package"
    let description = "Install a package using brew, pip, or npm (user-level, no sudo). Specify the package manager and package name."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "manager": JSONSchema.enumString(description: "Package manager", values: ["brew", "pip", "npm"]),
            "package": JSONSchema.string(description: "Package name to install"),
            "global": JSONSchema.boolean(description: "For npm: install globally with -g (default: false)")
        ], required: ["manager", "package"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let manager = try requiredString("manager", from: args)
        let pkg = try requiredString("package", from: args)
        let global = optionalBool("global", from: args) ?? false

        // Validate package name — prevent injection
        let safePkg = pkg.replacingOccurrences(of: "[^a-zA-Z0-9._@/\\-]", with: "", options: .regularExpression)
        guard !safePkg.isEmpty else {
            return "Invalid package name."
        }

        let command: String
        switch manager {
        case "brew": command = "brew install \(safePkg) 2>&1"
        case "pip": command = "pip3 install --user \(safePkg) 2>&1"
        case "npm":
            command = global ? "npm install -g \(safePkg) 2>&1" : "npm install \(safePkg) 2>&1"
        default: return "Unsupported manager."
        }

        let result = try ShellRunner.run(command, timeout: 120)
        let output = result.output
        let truncated = output.count > 2000 ? String(output.suffix(2000)) : output

        if result.exitCode == 0 {
            return "Installed \(safePkg) via \(manager) successfully.\n\(truncated)"
        }
        return "Install failed (exit \(result.exitCode)):\n\(truncated)"
    }
}

// MARK: - Diff Files

struct DiffFilesTool: ToolDefinition {
    let name = "diff_files"
    let description = "Compare two files or directories and show differences. Uses unified diff format."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "file_a": JSONSchema.string(description: "First file or directory path"),
            "file_b": JSONSchema.string(description: "Second file or directory path"),
            "context_lines": JSONSchema.integer(description: "Number of context lines (default: 3)", minimum: 0, maximum: 20)
        ], required: ["file_a", "file_b"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let fileA = try requiredString("file_a", from: args)
        let fileB = try requiredString("file_b", from: args)
        let context = optionalInt("context_lines", from: args) ?? 3

        let result = try ShellRunner.run(
            "diff -u -U \(context) \(fileA.shellEscaped()) \(fileB.shellEscaped()) 2>&1",
            timeout: 10
        )

        if result.exitCode == 0 {
            return "Files are identical."
        }

        let output = result.output
        if output.count > 5000 {
            return String(output.prefix(5000)) + "\n... (diff truncated)"
        }
        return output.isEmpty ? "Files differ (binary or empty diff)." : output
    }
}

// MARK: - Hash File

struct HashFileTool: ToolDefinition {
    let name = "hash_file"
    let description = "Compute the hash (MD5, SHA-1, or SHA-256) of a file. Useful for verifying downloads or comparing files."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Path to the file to hash"),
            "algorithm": JSONSchema.enumString(description: "Hash algorithm (default: sha256)", values: ["md5", "sha1", "sha256"])
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let algo = optionalString("algorithm", from: args) ?? "sha256"

        let command: String
        switch algo {
        case "md5": command = "md5 \(path.shellEscaped()) 2>&1"
        case "sha1": command = "shasum -a 1 \(path.shellEscaped()) 2>&1"
        case "sha256": command = "shasum -a 256 \(path.shellEscaped()) 2>&1"
        default: return "Unsupported algorithm."
        }

        let result = try ShellRunner.run(command, timeout: 15)
        if result.exitCode != 0 { return "Hash failed: \(result.output)" }
        return "\(algo.uppercased()): \(result.output)"
    }
}

// MARK: - Create Symlink

struct CreateSymlinkTool: ToolDefinition {
    let name = "create_symlink"
    let description = "Create a symbolic link pointing to a target file or directory."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "target": JSONSchema.string(description: "The file or directory the symlink points to"),
            "link_path": JSONSchema.string(description: "Where to create the symlink")
        ], required: ["target", "link_path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let target = try requiredString("target", from: args)
        let linkPath = try requiredString("link_path", from: args)

        let result = try ShellRunner.run("ln -s \(target.shellEscaped()) \(linkPath.shellEscaped()) 2>&1", timeout: 5)
        if result.exitCode == 0 {
            return "Created symlink: \(linkPath) → \(target)"
        }
        return "Failed: \(result.output)"
    }
}

// MARK: - Change Permissions

struct ChmodTool: ToolDefinition {
    let name = "chmod_file"
    let description = "Change file or directory permissions (e.g., make a script executable)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "File or directory path"),
            "mode": JSONSchema.string(description: "Permission mode (e.g., '+x', '755', 'u+rw')")
        ], required: ["path", "mode"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let mode = try requiredString("mode", from: args)

        // Validate mode — basic check
        let safeMode = mode.replacingOccurrences(of: "[^a-zA-Z0-9+\\-=,]", with: "", options: .regularExpression)
        let result = try ShellRunner.run("chmod \(safeMode) \(path.shellEscaped()) 2>&1", timeout: 5)
        if result.exitCode == 0 {
            return "Changed permissions of \(path) to \(safeMode)."
        }
        return "Failed: \(result.output)"
    }
}

// MARK: - Serve Directory (Quick HTTP Server)

struct ServeDirectoryTool: ToolDefinition {
    let name = "serve_directory"
    let description = "Start a simple HTTP server serving files from a directory. Returns the URL. The server runs in the background."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Directory to serve (defaults to current directory)"),
            "port": JSONSchema.integer(description: "Port number (default: 8000)", minimum: 1024, maximum: 65535)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = optionalString("path", from: args) ?? "."
        let port = optionalInt("port", from: args) ?? 8000

        // Check if port is already in use
        let check = try ShellRunner.run("lsof -i :\(port) -P -n 2>/dev/null | grep LISTEN", timeout: 3)
        if !check.output.isEmpty {
            return "Port \(port) is already in use. Choose a different port."
        }

        // Start Python HTTP server in background
        let expandedPath = (path as NSString).expandingTildeInPath
        let command = "cd \(expandedPath.shellEscaped()) && python3 -m http.server \(port) &>/dev/null &; echo $!"
        let result = try ShellRunner.run(command, timeout: 5)
        let pid = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        return "HTTP server running at http://localhost:\(port)/ (PID: \(pid), serving \(expandedPath))\nUse kill_process to stop it."
    }
}

// MARK: - Docker Operations

struct DockerTool: ToolDefinition {
    let name = "docker_command"
    let description = "Run Docker commands: list containers, images, start/stop containers, view logs, compose up/down. No removal commands."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(description: "Docker action", values: [
                "ps", "images", "start", "stop", "restart", "logs", "stats",
                "compose_up", "compose_down", "compose_status", "inspect", "pull"
            ]),
            "target": JSONSchema.string(description: "Container name/ID, image name, or compose file path"),
            "tail": JSONSchema.integer(description: "For 'logs': number of lines to show (default: 50)")
        ], required: ["action"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)
        let target = optionalString("target", from: args) ?? ""
        let tail = optionalInt("tail", from: args) ?? 50

        let command: String
        switch action {
        case "ps": command = "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}\\t{{.Image}}' 2>&1"
        case "images": command = "docker images --format 'table {{.Repository}}\\t{{.Tag}}\\t{{.Size}}\\t{{.CreatedSince}}' 2>&1"
        case "start": command = "docker start \(target.shellEscaped()) 2>&1"
        case "stop": command = "docker stop \(target.shellEscaped()) 2>&1"
        case "restart": command = "docker restart \(target.shellEscaped()) 2>&1"
        case "logs": command = "docker logs --tail \(tail) \(target.shellEscaped()) 2>&1"
        case "stats": command = "docker stats --no-stream --format 'table {{.Name}}\\t{{.CPUPerc}}\\t{{.MemUsage}}' 2>&1"
        case "inspect": command = "docker inspect --format '{{json .Config}}' \(target.shellEscaped()) 2>&1 | python3 -m json.tool 2>/dev/null || docker inspect \(target.shellEscaped()) 2>&1"
        case "pull": command = "docker pull \(target.shellEscaped()) 2>&1"
        case "compose_up": command = target.isEmpty ? "docker compose up -d 2>&1" : "docker compose -f \(target.shellEscaped()) up -d 2>&1"
        case "compose_down": command = target.isEmpty ? "docker compose down 2>&1" : "docker compose -f \(target.shellEscaped()) down 2>&1"
        case "compose_status": command = "docker compose ps 2>&1"
        default: return "Unknown action."
        }

        let result = try ShellRunner.run(command, timeout: 60)
        let output = result.output
        if output.count > 4000 {
            return String(output.prefix(4000)) + "\n... (truncated)"
        }
        return output.isEmpty ? "Command completed." : output
    }
}

// MARK: - Git Operations (write)

struct GitCommandTool: ToolDefinition {
    let name = "git_command"
    let description = "Run common git operations: add, commit, push, pull, checkout, branch, merge, stash, clone, init, diff, log. No destructive operations (no reset --hard, no force push)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(description: "Git action", values: [
                "add", "commit", "push", "pull", "checkout", "branch", "merge",
                "stash", "stash_pop", "clone", "init", "diff", "log", "fetch",
                "tag", "cherry_pick", "rebase"
            ]),
            "args": JSONSchema.string(description: "Arguments for the git command (e.g., file paths, branch name, commit message)"),
            "path": JSONSchema.string(description: "Working directory for the git command")
        ], required: ["action"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)
        let gitArgs = optionalString("args", from: args) ?? ""
        let path = optionalString("path", from: args)
        let cd = path != nil ? "cd \(path!.shellEscaped()) && " : ""

        // Block destructive patterns
        let combined = "\(action) \(gitArgs)".lowercased()
        let blocked = ["--force", "-f push", "reset --hard", "clean -f", "branch -D", "push --force"]
        for pattern in blocked {
            if combined.contains(pattern) {
                return "Blocked: '\(pattern)' is a destructive operation. Use run_shell_command if you really need this."
            }
        }

        let command: String
        switch action {
        case "add": command = "\(cd)git add \(gitArgs) 2>&1"
        case "commit": command = "\(cd)git commit \(gitArgs) 2>&1"
        case "push": command = "\(cd)git push \(gitArgs) 2>&1"
        case "pull": command = "\(cd)git pull \(gitArgs) 2>&1"
        case "checkout": command = "\(cd)git checkout \(gitArgs) 2>&1"
        case "branch": command = "\(cd)git branch \(gitArgs) 2>&1"
        case "merge": command = "\(cd)git merge \(gitArgs) 2>&1"
        case "stash": command = "\(cd)git stash \(gitArgs) 2>&1"
        case "stash_pop": command = "\(cd)git stash pop 2>&1"
        case "clone": command = "git clone \(gitArgs) 2>&1"
        case "init": command = "\(cd)git init \(gitArgs) 2>&1"
        case "diff": command = "\(cd)git diff \(gitArgs) 2>&1"
        case "log": command = "\(cd)git log --oneline -20 \(gitArgs) 2>&1"
        case "fetch": command = "\(cd)git fetch \(gitArgs) 2>&1"
        case "tag": command = "\(cd)git tag \(gitArgs) 2>&1"
        case "cherry_pick": command = "\(cd)git cherry-pick \(gitArgs) 2>&1"
        case "rebase": command = "\(cd)git rebase \(gitArgs) 2>&1"
        default: return "Unknown git action."
        }

        let result = try ShellRunner.run(command, timeout: 60)
        let output = result.output
        if output.count > 4000 {
            return String(output.prefix(4000)) + "\n... (truncated)"
        }
        return output.isEmpty ? "Git \(action) completed." : output
    }
}

// MARK: - Find & Replace in Files

struct FindReplaceTool: ToolDefinition {
    let name = "find_replace_in_files"
    let description = "Find and replace text across multiple files using sed. Supports regex. Shows which files were modified."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "find": JSONSchema.string(description: "Text or regex pattern to find"),
            "replace": JSONSchema.string(description: "Replacement text"),
            "path": JSONSchema.string(description: "Directory to search in (defaults to current directory)"),
            "file_pattern": JSONSchema.string(description: "Glob pattern for files to include (e.g., '*.swift', '*.py')"),
            "regex": JSONSchema.boolean(description: "Treat 'find' as regex (default: false)")
        ], required: ["find", "replace"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let find = try requiredString("find", from: args)
        let replace = try requiredString("replace", from: args)
        let path = optionalString("path", from: args) ?? "."
        let pattern = optionalString("file_pattern", from: args) ?? "*"
        let isRegex = optionalBool("regex", from: args) ?? false

        let escapedFind = isRegex ? find : find
            .replacingOccurrences(of: "/", with: "\\/")
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let escapedReplace = replace.replacingOccurrences(of: "/", with: "\\/")

        // First, find matching files
        let findCmd = "grep -rl \(find.shellEscaped()) \(path.shellEscaped()) --include=\(pattern.shellEscaped()) 2>/dev/null | head -50"
        let findResult = try ShellRunner.run(findCmd, timeout: 10)

        if findResult.output.isEmpty {
            return "No files contain '\(find)' matching pattern '\(pattern)' in \(path)."
        }

        let files = findResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Apply sed replacement
        for file in files {
            _ = try ShellRunner.run("sed -i '' 's/\(escapedFind)/\(escapedReplace)/g' \(file.shellEscaped()) 2>&1", timeout: 5)
        }

        return "Replaced '\(find)' → '\(replace)' in \(files.count) file(s):\n" + files.map { "  \($0)" }.joined(separator: "\n")
    }
}

// MARK: - Base64 Encode/Decode

struct Base64Tool: ToolDefinition {
    let name = "base64_convert"
    let description = "Encode or decode text/files using Base64."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(description: "encode or decode", values: ["encode", "decode"]),
            "text": JSONSchema.string(description: "Text to encode/decode (use this OR file_path)"),
            "file_path": JSONSchema.string(description: "File to encode/decode (use this OR text)")
        ], required: ["action"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)
        let text = optionalString("text", from: args)
        let filePath = optionalString("file_path", from: args)

        let command: String
        if let text = text {
            if action == "encode" {
                command = "echo -n \(text.shellEscaped()) | base64 2>&1"
            } else {
                command = "echo -n \(text.shellEscaped()) | base64 -d 2>&1"
            }
        } else if let fp = filePath {
            if action == "encode" {
                command = "base64 < \(fp.shellEscaped()) 2>&1"
            } else {
                command = "base64 -d < \(fp.shellEscaped()) 2>&1"
            }
        } else {
            return "Provide either 'text' or 'file_path'."
        }

        let result = try ShellRunner.run(command, timeout: 10)
        let output = result.output
        if output.count > 5000 {
            return String(output.prefix(5000)) + "\n... (truncated)"
        }
        return output
    }
}

// MARK: - JSON Processor

struct JsonProcessTool: ToolDefinition {
    let name = "json_process"
    let description = "Process JSON data: pretty-print, extract fields with jq-style queries, validate, or convert to CSV. Uses python3 for processing."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(description: "Processing action", values: ["pretty", "query", "validate", "keys", "flatten"]),
            "input": JSONSchema.string(description: "JSON string or file path to process"),
            "query": JSONSchema.string(description: "For 'query' action: dot-notation path like 'data.items[0].name' or Python expression")
        ], required: ["action", "input"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)
        let input = try requiredString("input", from: args)
        let query = optionalString("query", from: args) ?? ""

        // Determine if input is a file path or JSON string
        let isFile = FileManager.default.fileExists(atPath: (input as NSString).expandingTildeInPath)
        let loadCode = isFile
            ? "import json; f=open(\(input.pythonEscaped())); data=json.load(f)"
            : "import json, sys; data=json.loads(\(input.pythonEscaped()))"

        let processCode: String
        switch action {
        case "pretty":
            processCode = "print(json.dumps(data, indent=2, ensure_ascii=False))"
        case "validate":
            processCode = "print('Valid JSON'); print(f'Type: {type(data).__name__}'); print(f'Top-level keys: {list(data.keys()) if isinstance(data, dict) else len(data)}')"
        case "keys":
            processCode = """
            def show_keys(d, prefix=''):
                if isinstance(d, dict):
                    for k,v in d.items():
                        p = f'{prefix}.{k}' if prefix else k
                        t = type(v).__name__
                        print(f'{p} ({t})')
                        if isinstance(v, (dict, list)): show_keys(v, p)
                elif isinstance(d, list) and d:
                    print(f'{prefix}[] (list of {len(d)})')
                    show_keys(d[0], f'{prefix}[0]')
            show_keys(data)
            """
        case "query":
            processCode = """
            parts = \(query.pythonEscaped()).replace('[', '.').replace(']', '').split('.')
            result = data
            for p in parts:
                if not p: continue
                if p.isdigit(): result = result[int(p)]
                else: result = result[p]
            print(json.dumps(result, indent=2, ensure_ascii=False) if isinstance(result, (dict, list)) else result)
            """
        case "flatten":
            processCode = """
            def flatten(d, prefix=''):
                items = {}
                if isinstance(d, dict):
                    for k,v in d.items():
                        new_key = f'{prefix}.{k}' if prefix else k
                        items.update(flatten(v, new_key))
                elif isinstance(d, list):
                    for i,v in enumerate(d):
                        items.update(flatten(v, f'{prefix}[{i}]'))
                else:
                    items[prefix] = d
                return items
            for k,v in flatten(data).items(): print(f'{k}: {v}')
            """
        default:
            return "Unknown action."
        }

        let script = "\(loadCode)\n\(processCode)"
        let tempFile = NSTemporaryDirectory() + "executer_json_\(UUID().uuidString.prefix(8)).py"
        try script.write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let result = try ShellRunner.run("python3 \(tempFile.shellEscaped()) 2>&1", timeout: 10)
        let output = result.output
        if output.count > 5000 {
            return String(output.prefix(5000)) + "\n... (truncated)"
        }
        return result.exitCode == 0 ? output : "Error: \(output)"
    }
}

// MARK: - Cron Job Management

struct CronTool: ToolDefinition {
    let name = "cron_manage"
    let description = "List, add, or view cron jobs for the current user. No deletion."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(description: "Action to perform", values: ["list", "add"]),
            "schedule": JSONSchema.string(description: "For 'add': cron schedule (e.g., '0 9 * * *' for daily at 9am)"),
            "command": JSONSchema.string(description: "For 'add': command to run")
        ], required: ["action"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)

        switch action {
        case "list":
            let result = try ShellRunner.run("crontab -l 2>&1", timeout: 5)
            if result.output.contains("no crontab") { return "No cron jobs configured." }
            return "Current cron jobs:\n\(result.output)"

        case "add":
            let schedule = try requiredString("schedule", from: args)
            let command = try requiredString("command", from: args)
            let addCmd = "(crontab -l 2>/dev/null; echo '\(schedule) \(command)') | crontab - 2>&1"
            let result = try ShellRunner.run(addCmd, timeout: 5)
            if result.exitCode == 0 {
                return "Added cron job: \(schedule) \(command)"
            }
            return "Failed to add cron job: \(result.output)"

        default:
            return "Unknown action."
        }
    }
}

// MARK: - SSH Command

struct SSHCommandTool: ToolDefinition {
    let name = "ssh_command"
    let description = "Run a command on a remote host via SSH. Requires existing SSH key setup (no password prompts)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "host": JSONSchema.string(description: "SSH host (e.g., user@hostname or hostname)"),
            "command": JSONSchema.string(description: "Command to run on the remote host"),
            "port": JSONSchema.integer(description: "SSH port (default: 22)"),
            "identity_file": JSONSchema.string(description: "Path to SSH private key (optional)")
        ], required: ["host", "command"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let host = try requiredString("host", from: args)
        let command = try requiredString("command", from: args)
        let port = optionalInt("port", from: args) ?? 22
        let identityFile = optionalString("identity_file", from: args)

        var sshParts = ["ssh", "-o StrictHostKeyChecking=accept-new", "-o ConnectTimeout=10", "-p \(port)"]
        if let keyPath = identityFile {
            sshParts.append("-i \(keyPath.shellEscaped())")
        }
        sshParts.append(host.shellEscaped())
        sshParts.append(command.shellEscaped())

        let sshCommand = sshParts.joined(separator: " ") + " 2>&1"
        let result = try ShellRunner.run(sshCommand, timeout: 30)

        let output = result.output
        if output.count > 4000 {
            return "Exit \(result.exitCode):\n\(String(output.prefix(4000)))\n... (truncated)"
        }
        return result.exitCode == 0 ? output : "SSH error (exit \(result.exitCode)):\n\(output)"
    }
}

// MARK: - Create Python Venv

struct CreateVenvTool: ToolDefinition {
    let name = "create_venv"
    let description = "Create a Python virtual environment and optionally install packages into it."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Where to create the venv (e.g., './venv' or '~/projects/myenv')"),
            "packages": JSONSchema.string(description: "Space-separated packages to install after creation (e.g., 'requests flask numpy')"),
            "python": JSONSchema.string(description: "Python executable to use (default: python3)")
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let packages = optionalString("packages", from: args)
        let python = optionalString("python", from: args) ?? "python3"
        let expandedPath = (path as NSString).expandingTildeInPath

        // Create venv
        let createResult = try ShellRunner.run("\(python) -m venv \(expandedPath.shellEscaped()) 2>&1", timeout: 30)
        if createResult.exitCode != 0 {
            return "Failed to create venv: \(createResult.output)"
        }

        var output = "Created Python venv at \(expandedPath)"

        // Install packages if specified
        if let pkgs = packages, !pkgs.isEmpty {
            let pipPath = "\(expandedPath)/bin/pip"
            let installResult = try ShellRunner.run("\(pipPath.shellEscaped()) install \(pkgs) 2>&1", timeout: 120)
            if installResult.exitCode == 0 {
                output += "\nInstalled: \(pkgs)"
            } else {
                output += "\nPackage install failed: \(installResult.output.suffix(500))"
            }
        }

        // Show Python version in venv
        let verResult = try ShellRunner.run("\(expandedPath)/bin/python --version 2>&1", timeout: 5)
        output += "\nPython: \(verResult.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        output += "\nActivate with: source \(expandedPath)/bin/activate"

        return output
    }
}

// MARK: - Text Processing (sort, uniq, awk, wc)

struct TextProcessTool: ToolDefinition {
    let name = "text_process"
    let description = "Process text from a file or piped input: sort, unique, count, head, tail, reverse, column extract, frequency count."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(description: "Processing action", values: [
                "sort", "unique", "count", "head", "tail", "reverse",
                "column", "frequency", "filter", "number_lines"
            ]),
            "file": JSONSchema.string(description: "Input file path"),
            "text": JSONSchema.string(description: "Input text (alternative to file)"),
            "args": JSONSchema.string(description: "Additional args: for column=column number, head/tail=line count, filter=grep pattern")
        ], required: ["action"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)
        let file = optionalString("file", from: args)
        let text = optionalString("text", from: args)
        let extra = optionalString("args", from: args) ?? ""

        let input: String
        if let file = file {
            input = "cat \(file.shellEscaped())"
        } else if let text = text {
            input = "echo \(text.shellEscaped())"
        } else {
            return "Provide either 'file' or 'text'."
        }

        let pipe: String
        switch action {
        case "sort": pipe = "sort"
        case "unique": pipe = "sort | uniq"
        case "count": pipe = "wc -lwc"
        case "head": pipe = "head -\(extra.isEmpty ? "10" : extra)"
        case "tail": pipe = "tail -\(extra.isEmpty ? "10" : extra)"
        case "reverse": pipe = "tail -r"
        case "column": pipe = "awk '{print $\(extra.isEmpty ? "1" : extra)}'"
        case "frequency": pipe = "sort | uniq -c | sort -rn | head -20"
        case "filter": pipe = extra.isEmpty ? "cat" : "grep \(extra.shellEscaped())"
        case "number_lines": pipe = "nl"
        default: return "Unknown action."
        }

        let result = try ShellRunner.run("\(input) | \(pipe) 2>&1", timeout: 10)
        let output = result.output
        if output.count > 5000 {
            return String(output.prefix(5000)) + "\n... (truncated)"
        }
        return output.isEmpty ? "(empty result)" : output
    }
}

// MARK: - Watch File/Command

struct WatchCommandTool: ToolDefinition {
    let name = "watch_command"
    let description = "Run a command repeatedly and return when output changes, or run it once and capture output. Useful for polling build status, waiting for services."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "command": JSONSchema.string(description: "Shell command to watch"),
            "interval": JSONSchema.integer(description: "Check interval in seconds (default: 2)", minimum: 1, maximum: 30),
            "timeout": JSONSchema.integer(description: "Max wait time in seconds (default: 30)", minimum: 5, maximum: 120),
            "until_contains": JSONSchema.string(description: "Stop when output contains this string")
        ], required: ["command"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let command = try requiredString("command", from: args)
        let interval = optionalInt("interval", from: args) ?? 2
        let timeout = optionalInt("timeout", from: args) ?? 30
        let untilContains = optionalString("until_contains", from: args)

        let startTime = Date()
        var lastOutput = ""
        var iterations = 0

        while Date().timeIntervalSince(startTime) < TimeInterval(timeout) {
            let result = try ShellRunner.run(command, timeout: TimeInterval(min(timeout, 15)))
            let output = result.output
            iterations += 1

            if let target = untilContains {
                if output.contains(target) {
                    return "Condition met after \(iterations) check(s):\n\(output.prefix(3000))"
                }
            } else if output != lastOutput && !lastOutput.isEmpty {
                return "Output changed after \(iterations) check(s):\n\(output.prefix(3000))"
            }

            lastOutput = output
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }

        return "Timed out after \(timeout)s (\(iterations) checks). Last output:\n\(lastOutput.prefix(2000))"
    }
}

// MARK: - Clipboard Pipe

struct ClipboardPipeTool: ToolDefinition {
    let name = "clipboard_pipe"
    let description = "Run a command and copy its output to the clipboard, or process clipboard contents through a command."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "direction": JSONSchema.enumString(description: "'to_clipboard' = command output → clipboard, 'from_clipboard' = clipboard → command", values: ["to_clipboard", "from_clipboard"]),
            "command": JSONSchema.string(description: "Shell command to run")
        ], required: ["direction", "command"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let direction = try requiredString("direction", from: args)
        let command = try requiredString("command", from: args)

        let fullCommand: String
        switch direction {
        case "to_clipboard":
            fullCommand = "\(command) 2>&1 | pbcopy && echo 'Copied to clipboard'"
        case "from_clipboard":
            fullCommand = "pbpaste | \(command) 2>&1"
        default:
            return "Direction must be 'to_clipboard' or 'from_clipboard'."
        }

        let result = try ShellRunner.run(fullCommand, timeout: 15)
        return result.output.isEmpty ? "Done." : result.output
    }
}

// MARK: - SQLite Query

struct SqliteQueryTool: ToolDefinition {
    let name = "sqlite_query"
    let description = "Run a read-only SQL query against a SQLite database file. Great for inspecting app databases, logs, or data files."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "database": JSONSchema.string(description: "Path to the .sqlite or .db file"),
            "query": JSONSchema.string(description: "SQL query to execute (SELECT only — no INSERT/UPDATE/DELETE)"),
            "format": JSONSchema.enumString(description: "Output format (default: table)", values: ["table", "csv", "json"])
        ], required: ["database", "query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let database = try requiredString("database", from: args)
        let query = try requiredString("query", from: args)
        let format = optionalString("format", from: args) ?? "table"

        // Block write operations
        let lower = query.lowercased().trimmingCharacters(in: .whitespaces)
        let blocked = ["insert", "update", "delete", "drop", "alter", "create", "truncate", "replace"]
        for word in blocked {
            if lower.hasPrefix(word) {
                return "Blocked: Only SELECT queries are allowed. '\(word)' is a write operation."
            }
        }

        let modeFlag: String
        switch format {
        case "csv": modeFlag = "-csv -header"
        case "json": modeFlag = "-json"
        default: modeFlag = "-header -column"
        }

        let result = try ShellRunner.run(
            "sqlite3 \(modeFlag) \(database.shellEscaped()) \(query.shellEscaped()) 2>&1",
            timeout: 15
        )

        let output = result.output
        if output.count > 5000 {
            return String(output.prefix(5000)) + "\n... (truncated)"
        }
        return output.isEmpty ? "(no results)" : output
    }
}

// MARK: - File Watcher (fswatch)

struct FileWatcherTool: ToolDefinition {
    let name = "file_watcher"
    let description = "Watch a file or directory for changes and report what changed. Watches for a limited time and returns events."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "File or directory to watch"),
            "duration": JSONSchema.integer(description: "How long to watch in seconds (default: 10, max: 60)", minimum: 1, maximum: 60)
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let duration = optionalInt("duration", from: args) ?? 10

        // Use fswatch if available, fallback to polling
        let checkFswatch = try ShellRunner.run("which fswatch 2>/dev/null", timeout: 3)
        if !checkFswatch.output.isEmpty {
            let result = try ShellRunner.run(
                "timeout \(duration) fswatch -r --event Created --event Updated --event Removed \(path.shellEscaped()) 2>&1 || true",
                timeout: TimeInterval(duration + 2)
            )
            let events = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
            if events.isEmpty { return "No changes detected in \(duration) seconds." }
            return "Changes detected (\(events.count) events):\n" + events.prefix(20).joined(separator: "\n")
        }

        // Fallback: snapshot comparison
        _ = try ShellRunner.run("find \(path.shellEscaped()) -type f -newer /tmp/.executer_watch_marker 2>/dev/null; touch /tmp/.executer_watch_marker", timeout: 5)
        try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
        let after = try ShellRunner.run("find \(path.shellEscaped()) -type f -newer /tmp/.executer_watch_marker 2>/dev/null", timeout: 5)

        let changed = after.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        if changed.isEmpty { return "No changes detected in \(duration) seconds." }
        return "Files changed:\n" + changed.prefix(20).joined(separator: "\n")
    }
}

// MARK: - Image Convert

struct ImageConvertTool: ToolDefinition {
    let name = "image_convert"
    let description = "Convert images between formats or resize them using macOS sips. Supports PNG, JPEG, TIFF, GIF, BMP, HEIC."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "input": JSONSchema.string(description: "Input image path"),
            "output": JSONSchema.string(description: "Output image path (format inferred from extension)"),
            "width": JSONSchema.integer(description: "Resize to this width (maintains aspect ratio)"),
            "height": JSONSchema.integer(description: "Resize to this height (maintains aspect ratio)"),
            "quality": JSONSchema.integer(description: "JPEG quality 0-100 (default: 85)", minimum: 0, maximum: 100)
        ], required: ["input"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let input = try requiredString("input", from: args)
        let output = optionalString("output", from: args)
        let width = optionalInt("width", from: args)
        let height = optionalInt("height", from: args)

        var commands: [String] = []

        // Copy to output if different path
        let target: String
        if let out = output, out != input {
            commands.append("cp \(input.shellEscaped()) \(out.shellEscaped())")
            target = out
        } else {
            target = input
        }

        // Convert format if output extension differs
        if let out = output {
            let ext = URL(fileURLWithPath: out).pathExtension.lowercased()
            let formatMap = ["png": "png", "jpg": "jpeg", "jpeg": "jpeg", "tiff": "tiff", "gif": "gif", "bmp": "bmp", "heic": "heic"]
            if let fmt = formatMap[ext] {
                commands.append("sips -s format \(fmt) \(target.shellEscaped()) --out \(target.shellEscaped())")
            }
        }

        // Resize
        if let w = width {
            commands.append("sips --resampleWidth \(w) \(target.shellEscaped())")
        } else if let h = height {
            commands.append("sips --resampleHeight \(h) \(target.shellEscaped())")
        }

        if commands.isEmpty {
            // Just show info
            let result = try ShellRunner.run("sips -g all \(input.shellEscaped()) 2>&1 | head -15", timeout: 5)
            return "Image info:\n\(result.output)"
        }

        let fullCommand = commands.joined(separator: " && ") + " 2>&1"
        let result = try ShellRunner.run(fullCommand, timeout: 15)

        if result.exitCode != 0 {
            return "Conversion failed: \(result.output)"
        }

        // Show result
        let info = try ShellRunner.run("sips -g pixelWidth -g pixelHeight -g format \(target.shellEscaped()) 2>&1", timeout: 5)
        let sizeResult = try ShellRunner.run("ls -lh \(target.shellEscaped()) | awk '{print $5}'", timeout: 3)
        return "Converted → \(target) (\(sizeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)))\n\(info.output)"
    }
}

// MARK: - Rename File (safe rename, not delete)

struct RenameFileTool: ToolDefinition {
    let name = "rename_file"
    let description = "Rename a file or directory (move within the same parent). Safer than move — blocks cross-directory moves."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Current file path"),
            "new_name": JSONSchema.string(description: "New filename (just the name, not a full path)")
        ], required: ["path", "new_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let newName = try requiredString("new_name", from: args)

        // Ensure new_name doesn't contain path separators
        guard !newName.contains("/") else {
            return "new_name must be a filename only, not a path. Use move_file for cross-directory moves."
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let newPath = "\(parent)/\(newName)"

        let result = try ShellRunner.run("mv \(path.shellEscaped()) \(newPath.shellEscaped()) 2>&1", timeout: 5)
        if result.exitCode == 0 {
            return "Renamed: \(URL(fileURLWithPath: path).lastPathComponent) → \(newName)"
        }
        return "Failed: \(result.output)"
    }
}

// MARK: - System Profiler (hardware details)

struct SystemProfilerTool: ToolDefinition {
    let name = "system_profiler"
    let description = "Get detailed hardware information: model, serial, memory, storage, graphics, USB devices, Thunderbolt, audio."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "category": JSONSchema.enumString(description: "Info category", values: [
                "hardware", "memory", "storage", "graphics", "usb", "thunderbolt",
                "audio", "network", "bluetooth", "power", "software"
            ])
        ], required: ["category"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let category = try requiredString("category", from: args)

        let spType: String
        switch category {
        case "hardware": spType = "SPHardwareDataType"
        case "memory": spType = "SPMemoryDataType"
        case "storage": spType = "SPStorageDataType"
        case "graphics": spType = "SPDisplaysDataType"
        case "usb": spType = "SPUSBDataType"
        case "thunderbolt": spType = "SPThunderboltDataType"
        case "audio": spType = "SPAudioDataType"
        case "network": spType = "SPNetworkDataType"
        case "bluetooth": spType = "SPBluetoothDataType"
        case "power": spType = "SPPowerDataType"
        case "software": spType = "SPSoftwareDataType"
        default: return "Unknown category."
        }

        let result = try ShellRunner.run("system_profiler \(spType) 2>&1", timeout: 15)
        let output = result.output
        if output.count > 4000 {
            return String(output.prefix(4000)) + "\n... (truncated)"
        }
        return output
    }
}

// MARK: - Shell Escape Helper

private extension String {
    /// Escapes a string for safe use in shell commands.
    func shellEscaped() -> String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for use as a Python string literal.
    func pythonEscaped() -> String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'''\(escaped)'''"
    }
}

// MARK: - Section Parser Helper

/// Extracts text between two markers in shell output. Used by multiple tools.
private func extractSection(_ text: String, start: String, end: String?) -> String? {
    guard let startRange = text.range(of: start) else { return nil }
    let after = String(text[startRange.upperBound...])
    let content: String
    if let end = end, let endRange = after.range(of: end) {
        content = String(after[..<endRange.lowerBound])
    } else {
        content = after
    }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
}

import Foundation

/// Manages a local MLX Python classification server and provides a Swift interface.
/// Gracefully degrades — if the server is unavailable, classify() returns nil and
/// the routing pipeline falls through to existing tiers.
actor MLXClassifierService {
    static let shared = MLXClassifierService()

    struct ClassificationResult {
        let category: String
        let confidence: Double
    }

    // MARK: - Configuration

    private let port = 5127
    private let pythonPath = "\(NSHomeDirectory())/mlx-env/bin/python3"
    private let scriptPath = "\(NSHomeDirectory())/mlx-env/mlx_classifier_server.py"
    private let requestTimeout: TimeInterval = 0.5  // 500ms
    private let maxRestartAttempts = 3

    // MARK: - State

    private var process: Process?
    private var isReady = false
    private var restartCount = 0
    private var startTask: Task<Void, Never>?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: config)
    }()

    var isRunning: Bool {
        process?.isRunning == true && isReady
    }

    // MARK: - Lifecycle

    /// Start the Python MLX server. Non-blocking — polls /health until ready.
    func start() async {
        // Don't double-start
        if process?.isRunning == true {
            if isReady { return }
            stop()
        }

        // Check that the script and Python exist
        let fm = FileManager.default
        guard fm.fileExists(atPath: pythonPath),
              fm.fileExists(atPath: scriptPath) else {
            print("[MLXClassifier] Python or script not found, skipping")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath]

        // Inherit environment for HuggingFace cache paths
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.process = proc
        self.isReady = false

        proc.terminationHandler = { [weak self] p in
            Task { [weak self] in
                await self?.handleTermination(exitCode: p.terminationStatus)
            }
        }

        do {
            try proc.run()
            print("[MLXClassifier] Server process started (pid: \(proc.processIdentifier))")
        } catch {
            print("[MLXClassifier] Failed to start: \(error)")
            return
        }

        // Poll /health until the model is loaded
        await waitForReady()
    }

    func stop() {
        startTask?.cancel()
        startTask = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            print("[MLXClassifier] Server stopped")
        }
        process = nil
        isReady = false
    }

    // MARK: - Classification

    /// Classify user input. Returns nil if the server is unavailable or on any error.
    func classify(_ text: String) async -> ClassificationResult? {
        guard isReady else { return nil }

        let url = URL(string: "http://127.0.0.1:\(port)/classify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["text": text]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let category = json["category"] as? String,
                  let confidence = json["confidence"] as? Double else { return nil }

            return ClassificationResult(category: category, confidence: confidence)
        } catch {
            // Timeout, connection refused, etc. — silent fallthrough
            return nil
        }
    }

    // MARK: - Private

    private func waitForReady() async {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let maxPolls = 75  // 75 * 200ms = 15 seconds

        for _ in 0..<maxPolls {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

            guard process?.isRunning == true else {
                print("[MLXClassifier] Process exited during startup")
                return
            }

            do {
                let (_, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    isReady = true
                    restartCount = 0
                    print("[MLXClassifier] Ready")
                    return
                }
            } catch {
                continue
            }
        }

        print("[MLXClassifier] Timed out waiting for server to become ready")
    }

    private func handleTermination(exitCode: Int32) {
        let wasReady = isReady
        isReady = false
        process = nil

        if wasReady {
            print("[MLXClassifier] Server terminated unexpectedly (exit \(exitCode))")
            // Try to restart
            if restartCount < maxRestartAttempts {
                restartCount += 1
                print("[MLXClassifier] Restarting (attempt \(restartCount)/\(maxRestartAttempts))")
                Task { await start() }
            } else {
                print("[MLXClassifier] Max restart attempts reached, disabling for this session")
            }
        }
    }
}

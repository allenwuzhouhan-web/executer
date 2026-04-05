import Foundation
import AppKit

/// Background daemon that keeps the ObservationStream alive across app lifecycle.
///
/// Responsibilities:
/// 1. Manages adaptive screen sampling (periodic AX tree reads) and emits ScreenSampleEvents
/// 2. Survives screen lock/unlock — pauses sampling when locked, resumes on unlock
/// 3. Monitors observer health — detects if sources stop emitting and logs warnings
/// 4. Manages stream consumers — fans out the throttled stream to registered consumers
///
/// This is the "always-on" heartbeat of the Workflow Recorder.
actor ContinuousPerceptionDaemon {
    static let shared = ContinuousPerceptionDaemon()

    // MARK: - State

    private var isRunning = false
    private var isScreenLocked = false
    private var screenSamplingTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?

    /// Registered consumers of the throttled observation stream.
    /// Each consumer receives every event from the deduplicated stream.
    private var consumers: [(String, @Sendable (ObservationEvent) async -> Void)] = []

    /// The throttler that deduplicates raw events.
    private let throttler = ObservationThrottler()

    // MARK: - Health Monitoring

    private var lastEventTimeBySource: [String: Date] = [:]
    /// If a source hasn't emitted in this many seconds, log a warning.
    private let sourceTimeout: TimeInterval = 300  // 5 minutes

    // MARK: - Lifecycle

    /// Start the daemon. Wires up ObservationStream → Throttler → Consumers.
    func start() async {
        guard !isRunning else { return }
        isRunning = true

        // 1. Start the raw observation stream
        let rawStream = await ObservationStream.shared.start()

        // 2. Start the AppObserver and other sources (they wire into ObservationStream)
        AppObserver.shared.start()
        FileMonitor.shared.start()
        ClipboardObserver.shared.start()

        // 3. Filter through throttler
        let filteredStream = await throttler.filter(raw: rawStream)

        // 4. Start consumer fan-out (utility priority — never compete with user work)
        consumerTask = Task(priority: .utility) { [weak self] in
            for await event in filteredStream {
                guard let self = self else { break }
                await self.dispatch(event)
            }
        }

        // 5. Start screen sampling
        startScreenSampling()

        // 6. Start health monitoring
        startHealthCheck()

        print("[Daemon] ContinuousPerceptionDaemon started — always-on observation active")
    }

    /// Stop the daemon and all associated tasks.
    func stop() async {
        guard isRunning else { return }
        isRunning = false

        screenSamplingTask?.cancel()
        healthCheckTask?.cancel()
        consumerTask?.cancel()

        screenSamplingTask = nil
        healthCheckTask = nil
        consumerTask = nil

        await ObservationStream.shared.stop()

        AppObserver.shared.stop()
        FileMonitor.shared.stop()
        ClipboardObserver.shared.stop()

        let throttlerStats = await throttler.passedCount
        print("[Daemon] Stopped — \(throttlerStats) events delivered to consumers")
    }

    // MARK: - Consumer Registration

    /// Register a named consumer that will receive all throttled events.
    func addConsumer(name: String, handler: @escaping @Sendable (ObservationEvent) async -> Void) {
        consumers.append((name, handler))
        print("[Daemon] Registered consumer: \(name)")
    }

    /// Remove a consumer by name.
    func removeConsumer(name: String) {
        consumers.removeAll { $0.0 == name }
        print("[Daemon] Removed consumer: \(name)")
    }

    // MARK: - Event Dispatch

    private func dispatch(_ event: ObservationEvent) async {
        // Track last event time per source for health monitoring
        lastEventTimeBySource[event.source.rawValue] = event.timestamp

        // Fan out to all registered consumers
        for (name, handler) in consumers {
            await handler(event)
        }
    }

    // MARK: - Screen Sampling

    /// Adaptive screen sampling — reads visible text from frontmost app periodically.
    /// Rate adapts based on LearningConfig and TeachMeMode state.
    private func startScreenSampling() {
        screenSamplingTask?.cancel()

        screenSamplingTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                let isLocked = await self.isScreenLocked
                let running = await self.isRunning

                guard running, !isLocked else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s retry when paused
                    continue
                }

                // Determine sampling interval
                let interval: TimeInterval
                if TeachMeMode.shared.isActive {
                    interval = 5  // High-frequency during teach-me mode
                } else if LearningConfig.shared.isScreenSamplingEnabled {
                    interval = AdaptiveSampling.shared.currentInterval
                } else {
                    interval = 60  // Fallback
                }

                // Sample the screen
                await self.sampleScreen()

                // Sleep for the interval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// dHash of the last screen capture per app, for pixel-level change detection.
    private var lastScreenHash: [String: UInt64] = [:]

    /// Minimum dHash Hamming distance to consider a screen change meaningful.
    private let dHashChangeThreshold = 10

    /// Take a single screen sample and emit it into the ObservationStream.
    /// Uses dHash to suppress samples when the screen hasn't meaningfully changed.
    private func sampleScreen() async {
        guard let app = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }),
              let name = await MainActor.run(body: { app.localizedName }),
              await MainActor.run(body: { app.bundleIdentifier }) != "com.allenwu.executer" else {
            return
        }

        let pid = app.processIdentifier

        // Compute dHash for pixel-level change detection
        var screenHash: UInt64?
        if let screenshot = ScreenCapture.captureMainDisplay() {
            let hash = ScreenCapture.dHash(screenshot)
            if let previousHash = lastScreenHash[name] {
                let distance = ScreenCapture.hammingDistance(hash, previousHash)
                if distance < 3 {
                    return  // Cursor blink, clock tick — suppress
                }
            }
            lastScreenHash[name] = hash
            screenHash = hash
        }

        let texts = ScreenReader.readVisibleText(pid: pid)
        guard !texts.isEmpty || screenHash != nil else { return }

        let sample = ScreenSampleEvent(
            appName: name,
            pid: pid,
            visibleTextPreview: Array(texts.prefix(20)),
            elementCount: texts.count,
            timestamp: Date(),
            screenHash: screenHash
        )

        await ObservationStream.shared.emit(.screenSample(sample))
    }

    // MARK: - Health Monitoring

    /// Periodically checks that all observation sources are still emitting.
    private func startHealthCheck() {
        healthCheckTask?.cancel()

        healthCheckTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)  // Check every 60s
                guard let self = self else { break }
                await self.checkHealth()
            }
        }
    }

    private func checkHealth() {
        guard !isScreenLocked else { return }  // Don't flag sources during screen lock

        let now = Date()
        let expectedSources: [ObservationEvent.EventSource] = [.accessibility, .fileSystem, .clipboard]

        for source in expectedSources {
            if let lastTime = lastEventTimeBySource[source.rawValue] {
                let gap = now.timeIntervalSince(lastTime)
                if gap > sourceTimeout {
                    print("[Daemon] Warning: \(source.rawValue) source silent for \(Int(gap))s — attempting recovery")
                    recoverSource(source)
                }
            }
        }
    }

    /// Attempt to restart a dead observation source.
    private nonisolated func recoverSource(_ source: ObservationEvent.EventSource) {
        switch source {
        case .accessibility:
            AppObserver.shared.stop()
            AppObserver.shared.start()
            print("[Daemon] Recovered accessibility observer")
        case .fileSystem:
            FileMonitor.shared.stop()
            FileMonitor.shared.start()
            print("[Daemon] Recovered file monitor")
        case .clipboard:
            ClipboardObserver.shared.stop()
            ClipboardObserver.shared.start()
            print("[Daemon] Recovered clipboard observer")
        default:
            break
        }
    }

    // MARK: - Screen Lock Handling

    /// Called by ObservationStream's system event consumer to pause/resume sampling.
    func handleScreenLock() {
        isScreenLocked = true
        print("[Daemon] Screen locked — pausing screen sampling")
    }

    func handleScreenUnlock() {
        isScreenLocked = false
        print("[Daemon] Screen unlocked — resuming screen sampling")
    }
}

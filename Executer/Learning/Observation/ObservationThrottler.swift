import Foundation

/// Intelligent event deduplication and coalescing for the ObservationStream.
///
/// Reduces noise without losing signal:
/// - Rapid textEdit events from the same element coalesced into one (2s window)
/// - Burst file modifications in the same directory coalesced (2s window)
/// - Consecutive duplicate focus events on the same element suppressed
/// - Screen samples suppressed if content hash unchanged
///
/// Operates as an async filter: consumes raw events, emits deduplicated events.
actor ObservationThrottler {

    // MARK: - Configuration

    /// Window for coalescing rapid text edits on the same element.
    private let textEditCoalesceWindow: TimeInterval = 2.0

    /// Window for coalescing burst file events in the same directory.
    private let fileEventCoalesceWindow: TimeInterval = 2.0

    /// Minimum interval between screen samples for the same app.
    private let screenSampleMinInterval: TimeInterval = 10.0

    // MARK: - State

    /// Last text edit event per element key, for coalescing.
    private var pendingTextEdits: [String: (event: ObservationEvent, timer: Task<Void, Never>)] = [:]

    /// Last file event per directory, for coalescing.
    private var pendingFileEvents: [String: (event: ObservationEvent, timer: Task<Void, Never>)] = [:]

    /// Last focus event signature, for duplicate suppression.
    private var lastFocusSignature: String?

    /// Last screen sample time per app, for rate limiting.
    private var lastScreenSampleTime: [String: Date] = [:]

    /// Last screen sample content hash per app, for change detection.
    private var lastScreenSampleHash: [String: Int] = [:]

    /// Output continuation — receives deduplicated events.
    private var outputContinuation: AsyncStream<ObservationEvent>.Continuation?

    // MARK: - Stats

    private(set) var suppressedCount: UInt64 = 0
    private(set) var coalescedCount: UInt64 = 0
    private(set) var passedCount: UInt64 = 0

    // MARK: - Pipeline

    /// Creates a filtered stream from the raw observation stream.
    /// Returns an AsyncStream that emits only deduplicated events.
    func filter(raw: AsyncStream<ObservationEvent>) -> AsyncStream<ObservationEvent> {
        let (filtered, continuation) = AsyncStream<ObservationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(5_000)
        )
        self.outputContinuation = continuation

        Task { [weak self] in
            for await event in raw {
                await self?.process(event)
            }
            // Raw stream ended — flush pending events and finish
            await self?.flushAll()
            continuation.finish()
        }

        return filtered
    }

    /// Process a single event through throttling rules.
    private func process(_ event: ObservationEvent) {
        switch event {
        case .userAction(let action):
            processUserAction(action, event: event)
        case .fileEvent(let fileEvent):
            processFileEvent(fileEvent, event: event)
        case .screenSample(let sample):
            processScreenSample(sample, event: event)
        case .clipboardFlow, .systemEvent:
            // Clipboard flows and system events are always passed through — they're low frequency.
            pass(event)
        }
    }

    // MARK: - User Action Throttling

    private func processUserAction(_ action: UserAction, event: ObservationEvent) {
        switch action.type {
        case .textEdit:
            // Coalesce rapid text edits on the same element.
            // Key = app + role + title (identifies the element being edited).
            let key = "\(action.appName):\(action.elementRole):\(action.elementTitle)"

            // Cancel any pending emit for this element
            pendingTextEdits[key]?.timer.cancel()

            // Schedule a new delayed emit — the latest edit "wins" after the coalesce window.
            let timer = Task { [weak self, textEditCoalesceWindow] in
                try? await Task.sleep(nanoseconds: UInt64(textEditCoalesceWindow * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.emitPendingTextEdit(key: key)
            }

            pendingTextEdits[key] = (event: event, timer: timer)
            coalescedCount += 1

        case .focus:
            // Suppress consecutive duplicate focus events on the same element.
            let sig = action.signature
            if sig == lastFocusSignature {
                suppressedCount += 1
                return
            }
            lastFocusSignature = sig
            pass(event)

        case .textSelect:
            // Coalesce rapid text selection changes (1s window, shorter than text edit)
            let key = "sel:\(action.appName):\(action.elementRole):\(action.elementTitle)"
            pendingTextEdits[key]?.timer.cancel()
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s coalesce
                guard !Task.isCancelled else { return }
                await self?.emitPendingTextEdit(key: key)
            }
            pendingTextEdits[key] = (event: event, timer: timer)
            coalescedCount += 1

        case .click, .windowOpen, .menuSelect, .tabSwitch:
            // These are always meaningful — pass through.
            lastFocusSignature = nil  // Reset focus tracking on explicit action
            pass(event)
        }
    }

    private func emitPendingTextEdit(key: String) {
        guard let pending = pendingTextEdits.removeValue(forKey: key) else { return }
        pass(pending.event)
    }

    // MARK: - File Event Throttling

    private func processFileEvent(_ fileEvent: FileObservationEvent, event: ObservationEvent) {
        // Coalesce burst file events in the same directory.
        let key = fileEvent.directory

        pendingFileEvents[key]?.timer.cancel()

        let timer = Task { [weak self, fileEventCoalesceWindow] in
            try? await Task.sleep(nanoseconds: UInt64(fileEventCoalesceWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.emitPendingFileEvent(key: key)
        }

        pendingFileEvents[key] = (event: event, timer: timer)
        coalescedCount += 1
    }

    private func emitPendingFileEvent(key: String) {
        guard let pending = pendingFileEvents.removeValue(forKey: key) else { return }
        pass(pending.event)
    }

    // MARK: - Screen Sample Throttling

    private func processScreenSample(_ sample: ScreenSampleEvent, event: ObservationEvent) {
        let app = sample.appName

        // Rate limit: skip if too recent for this app.
        if let lastTime = lastScreenSampleTime[app],
           Date().timeIntervalSince(lastTime) < screenSampleMinInterval {
            suppressedCount += 1
            return
        }

        // Content hash: skip if nothing changed.
        let hash = sample.visibleTextPreview.hashValue
        if hash == lastScreenSampleHash[app] {
            suppressedCount += 1
            return
        }

        lastScreenSampleTime[app] = Date()
        lastScreenSampleHash[app] = hash
        pass(event)
    }

    // MARK: - Output

    private func pass(_ event: ObservationEvent) {
        passedCount += 1
        outputContinuation?.yield(event)
    }

    /// Flush all pending events (called when raw stream ends).
    private func flushAll() {
        for (_, pending) in pendingTextEdits {
            pending.timer.cancel()
            pass(pending.event)
        }
        pendingTextEdits.removeAll()

        for (_, pending) in pendingFileEvents {
            pending.timer.cancel()
            pass(pending.event)
        }
        pendingFileEvents.removeAll()

        print("[Throttler] Final stats — passed: \(passedCount), coalesced: \(coalescedCount), suppressed: \(suppressedCount)")
    }
}

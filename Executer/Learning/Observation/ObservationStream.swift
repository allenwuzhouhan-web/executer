import Foundation
import AppKit

/// Unified observation stream that merges all five observation sources
/// (AppObserver, FileMonitor, ClipboardObserver, ScreenSampler, SystemEventBus)
/// into a single ordered AsyncStream<ObservationEvent>.
///
/// This is the foundation of the Workflow Recorder (Phase 1: "The Eternal Witness").
/// Guarantees: ordered delivery, backpressure via bounded buffer, no dropped events
/// under normal load.
actor ObservationStream {
    static let shared = ObservationStream()

    // MARK: - Stream Infrastructure

    private var continuation: AsyncStream<ObservationEvent>.Continuation?
    private var stream: AsyncStream<ObservationEvent>?
    private var isRunning = false

    /// Sequence number for ordering events from different sources.
    private var sequenceNumber: UInt64 = 0

    /// Notification observer tokens — stored for cleanup on stop.
    private var notificationObservers: [Any] = []

    /// Statistics for monitoring pipeline health.
    private(set) var stats = Stats()

    struct Stats: Sendable {
        var totalEvents: UInt64 = 0
        var droppedEvents: UInt64 = 0
        var eventsBySource: [String: UInt64] = [:]
        var lastEventTime: Date?
    }

    /// Buffer size — large enough to absorb bursts, small enough to bound memory.
    /// At ~100 bytes/event, 10K events ≈ 1MB.
    private static let bufferSize = 10_000

    // MARK: - Lifecycle

    /// Start the observation stream. Wires all five sources.
    /// Returns the AsyncStream that consumers can iterate over.
    func start() -> AsyncStream<ObservationEvent> {
        guard !isRunning else {
            return stream ?? AsyncStream<ObservationEvent> { $0.finish() }
        }

        let (newStream, newContinuation) = AsyncStream<ObservationEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.bufferSize)
        )

        self.stream = newStream
        self.continuation = newContinuation
        self.isRunning = true

        wireAppObserver()
        wireFileMonitor()
        wireClipboardObserver()
        wireSystemEventBus()

        print("[ObservationStream] Started — merging all observation sources")
        return newStream
    }

    /// Stop the observation stream. Finishes the AsyncStream.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        continuation?.finish()
        continuation = nil
        stream = nil

        // Remove notification observers to prevent duplicate events on restart
        for observer in notificationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        notificationObservers.removeAll()

        print("[ObservationStream] Stopped — total events: \(stats.totalEvents), dropped: \(stats.droppedEvents)")
    }

    /// Manually emit an event into the stream (used by ContinuousPerceptionDaemon for screen samples).
    func emit(_ event: ObservationEvent) {
        guard isRunning else { return }
        let result = continuation?.yield(event)
        recordYield(result, source: event.source)
    }

    // MARK: - Source Wiring

    /// Wire AppObserver — accessibility events (focus, click, textEdit, windowOpen, menuSelect).
    private func wireAppObserver() {
        // AppObserver runs on main thread with AX callbacks.
        // We capture the continuation reference for the callback closure.
        let cont = self.continuation
        AppObserver.shared.onAction = { [weak self] action in
            let event = ObservationEvent.userAction(action)
            let result = cont?.yield(event)
            Task { await self?.recordYield(result, source: .accessibility) }
        }
    }

    /// Wire FileMonitor — file system events (created, modified, deleted, renamed).
    private func wireFileMonitor() {
        let cont = self.continuation
        FileMonitor.shared.onFileEvent = { [weak self] fileEvent in
            let event = ObservationEvent.fileEvent(FileObservationEvent(from: fileEvent))
            let result = cont?.yield(event)
            Task { await self?.recordYield(result, source: .fileSystem) }
        }
    }

    /// Wire ClipboardObserver — clipboard flow events (copy → paste across apps).
    private func wireClipboardObserver() {
        let cont = self.continuation
        ClipboardObserver.shared.onClipboardFlow = { [weak self] flow in
            let event = ObservationEvent.clipboardFlow(ClipboardObservationEvent(from: flow))
            let result = cont?.yield(event)
            Task { await self?.recordYield(result, source: .clipboard) }
        }
    }

    /// Wire SystemEventBus — subscribe to system events via NotificationCenter.
    /// SystemEventBus fires automation rules; we tap into the same notifications
    /// to capture events without modifying SystemEventBus itself.
    private func wireSystemEventBus() {
        let workspace = NSWorkspace.shared

        // App launch
        let obs1 = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName else { return }
            let event = ObservationEvent.systemEvent(SystemObservationEvent(
                kind: .appLaunched(name: name), timestamp: Date()
            ))
            Task { await self?.emit(event) }
        }
        notificationObservers.append(obs1)

        // App quit
        let obs2 = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName else { return }
            let event = ObservationEvent.systemEvent(SystemObservationEvent(
                kind: .appQuit(name: name), timestamp: Date()
            ))
            Task { await self?.emit(event) }
        }
        notificationObservers.append(obs2)

        // Screen lock/unlock
        let obs3 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: nil
        ) { [weak self] _ in
            let event = ObservationEvent.systemEvent(SystemObservationEvent(
                kind: .screenLocked, timestamp: Date()
            ))
            Task { await self?.emit(event) }
        }
        notificationObservers.append(obs3)

        let obs4 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: nil
        ) { [weak self] _ in
            let event = ObservationEvent.systemEvent(SystemObservationEvent(
                kind: .screenUnlocked, timestamp: Date()
            ))
            Task { await self?.emit(event) }
        }
        notificationObservers.append(obs4)
    }

    // MARK: - ObservationEngine Wiring

    func wireObservationEngine() {
        let cont = self.continuation
        URLObserver.shared.onURLEvent = { [weak self] urlEvent in
            let result = cont?.yield(.oeURLEvent(urlEvent))
            Task { await self?.recordYield(result, source: .observationEngine) }
            ObservationStore.shared.record(.url(urlEvent))
        }
        ActivityObserver.shared.onActivityEvent = { [weak self] activityEvent in
            let result = cont?.yield(.oeActivityEvent(activityEvent))
            Task { await self?.recordYield(result, source: .observationEngine) }
            ObservationStore.shared.record(.activity(activityEvent))
        }
        TransitionObserver.shared.onTransitionEvent = { [weak self] transitionEvent in
            let result = cont?.yield(.oeTransitionEvent(transitionEvent))
            Task { await self?.recordYield(result, source: .observationEngine) }
            ObservationStore.shared.record(.transition(transitionEvent))
        }
        TransitionObserver.shared.onAppEvent = { [weak self] appEvent in
            let result = cont?.yield(.oeAppEvent(appEvent))
            Task { await self?.recordYield(result, source: .observationEngine) }
            ObservationStore.shared.record(.app(appEvent))
        }
        let origFileHandler = FileMonitor.shared.onFileEvent
        FileMonitor.shared.onFileEvent = { fileEvent in
            origFileHandler?(fileEvent)
            let oeFile = OEFileEvent(
                timestamp: fileEvent.timestamp, fileExtension: fileEvent.fileExtension,
                directory: fileEvent.directory,
                eventType: ObservedFileEventType(rawValue: fileEvent.eventType.rawValue) ?? .modified,
                appBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            ObservationStore.shared.record(.file(oeFile))
        }
    }

    // MARK: - Stats Tracking

    private func recordYield(
        _ result: AsyncStream<ObservationEvent>.Continuation.YieldResult?,
        source: ObservationEvent.EventSource
    ) {
        stats.totalEvents += 1
        stats.lastEventTime = Date()
        stats.eventsBySource[source.rawValue, default: 0] += 1

        if case .dropped = result {
            stats.droppedEvents += 1
            if stats.droppedEvents % 100 == 1 {
                print("[ObservationStream] Warning: dropped events (\(stats.droppedEvents) total). Buffer may be full.")
            }
        }
    }
}

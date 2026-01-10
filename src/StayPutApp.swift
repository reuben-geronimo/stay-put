import SwiftUI
import AppKit
import ApplicationServices

@main
struct StayPutApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static let defaultTopPadding: CGFloat = 10

    @Published var isEnabled: Bool = false
    @Published var statusMessage: String? = nil

    private let mouseLockService = MouseLockService()

    func setEnabled(_ enabled: Bool) {
        statusMessage = nil

        if enabled {
            do {
                try mouseLockService.start(topPadding: Self.defaultTopPadding)
                isEnabled = true
            } catch {
                // Minimal fail-safe: don’t stay enabled if permissions are missing or tap creation fails.
                isEnabled = false
                statusMessage = error.localizedDescription
            }
        } else {
            mouseLockService.stop()
            isEnabled = false
        }
    }
}

// MARK: - Services (Phase 1 only)

private enum MouseLockError: LocalizedError {
    case accessibilityPermissionDenied
    case inputMonitoringPermissionDenied
    case eventTapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Missing permissions. Enable both Accessibility and Input Monitoring in System Settings → Privacy & Security, then try again."
        case .inputMonitoringPermissionDenied:
            return "Missing Input Monitoring permission. Enable it in System Settings → Privacy & Security → Input Monitoring, then quit and relaunch StayPut. If StayPut doesn’t appear in the list, quit System Settings and toggle again."
        case .eventTapCreationFailed:
            return "Could not create the event tap. This usually means Accessibility and/or Input Monitoring permissions are missing."
        }
    }
}

private struct PermissionService {
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        guard prompt else { return false }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

private struct InputMonitoringPermissionService {
    /// Checks whether we have Input Monitoring (“Listen Event”) access.
    static func hasListenEventAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Triggers the system prompt / registers the app under Input Monitoring.
    /// Note: user approval may not take effect until the app is relaunched.
    static func requestListenEventAccess() {
        CGRequestListenEventAccess()
    }
}

private struct ScreenBoundsService {
    /// Menu Bar Guard (top-only): exclude the top reserved area (menu bar / notch safe area)
    /// but do NOT exclude the dock. Applies extra configurable top padding.
    static func menuBarGuardBounds(for cursorPoint: CGPoint, topPadding: CGFloat) -> CGRect? {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) }) ?? NSScreen.main
        guard let screen else { return nil }

        let overshootBufferTop: CGFloat = 20

        let frame = screen.frame
        let visible = screen.visibleFrame

        let topReserved = max(0, frame.maxY - visible.maxY)
        let maxY = frame.maxY - topReserved - max(0, topPadding) - overshootBufferTop

        guard maxY > frame.minY else { return nil }

        return CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: maxY - frame.minY
        )
    }
}

private final class MouseLockService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    private var topPadding: CGFloat = AppState.defaultTopPadding

    // Recursion guard for self-generated warp events.
    private let warpGuardLock = NSLock()
    private var lastWarpTimestampSeconds: Double = 0
    private var lastWarpPoint: CGPoint = .zero

    private let warpGuardWindowSeconds: Double = 0.008
    private let warpGuardDistance: CGFloat = 0.75

    func start(topPadding: CGFloat) throws {
        if isRunning {
            self.topPadding = topPadding
            return
        }

        guard PermissionService.ensureAccessibilityPermission(prompt: true) else {
            throw MouseLockError.accessibilityPermissionDenied
        }

        if !InputMonitoringPermissionService.hasListenEventAccess() {
            InputMonitoringPermissionService.requestListenEventAccess()
            // The decision often applies only after relaunch; fail fast with a clear message.
            throw MouseLockError.inputMonitoringPermissionDenied
        }

        self.topPadding = topPadding

        let startedSemaphore = DispatchSemaphore(value: 0)
        var startError: Error? = nil

        let thread = Thread { [weak self] in
            guard let self else { return }
            startError = self.installEventTap()
            startedSemaphore.signal()
            guard startError == nil else { return }
            CFRunLoopRun()
        }
        thread.name = "MouseLockService.EventTapThread"
        self.thread = thread
        thread.start()

        startedSemaphore.wait()
        if let startError {
            stop()
            throw startError
        }
    }

    func stop() {
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil

        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        runLoop = nil
        thread = nil
    }

    private var isRunning: Bool {
        eventTap != nil
    }

    private func installEventTap() -> Error? {
        let eventsOfInterest: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: Self.eventTapCallback,
            userInfo: refcon
        ) else {
            return MouseLockError.eventTapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let rl = CFRunLoopGetCurrent()
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.runLoop = rl

        return nil
    }

    private func shouldIgnoreWarpEvent(_ event: CGEvent) -> Bool {
        let nowSeconds = Double(event.timestamp) / 1_000_000_000.0
        let loc = event.location

        warpGuardLock.lock()
        defer { warpGuardLock.unlock() }

        let withinTime = (nowSeconds - lastWarpTimestampSeconds) >= 0 && (nowSeconds - lastWarpTimestampSeconds) < warpGuardWindowSeconds
        guard withinTime else { return false }

        let dx = loc.x - lastWarpPoint.x
        let dy = loc.y - lastWarpPoint.y
        return (dx * dx + dy * dy) <= (warpGuardDistance * warpGuardDistance)
    }

    private func recordWarp(to point: CGPoint, event: CGEvent) {
        let nowSeconds = Double(event.timestamp) / 1_000_000_000.0
        warpGuardLock.lock()
        lastWarpTimestampSeconds = nowSeconds
        lastWarpPoint = point
        warpGuardLock.unlock()
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<MouseLockService>.fromOpaque(userInfo).takeUnretainedValue()

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = service.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        // Recursion guard: suppress self-generated warp events.
        if service.shouldIgnoreWarpEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        guard let bounds = ScreenBoundsService.menuBarGuardBounds(for: event.location, topPadding: service.topPadding) else {
            return Unmanaged.passUnretained(event)
        }
        guard bounds.width >= 2, bounds.height >= 2 else {
            return Unmanaged.passUnretained(event)
        }

        let loc = event.location
        let clamped = CGPoint(
            x: clamp(loc.x, min: bounds.minX, max: bounds.maxX - 1),
            y: clamp(loc.y, min: bounds.minY, max: bounds.maxY - 1)
        )

        if clamped.x != loc.x || clamped.y != loc.y {
            service.recordWarp(to: clamped, event: event)
            CGWarpMouseCursorPosition(clamped)
            event.location = clamped
        }

        return Unmanaged.passUnretained(event)
    }
}

private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, min), max)
}

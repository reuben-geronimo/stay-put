import SwiftUI
import AppKit
import ApplicationServices
import IOKit.hid

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
    @Published var isEnabled: Bool = false
    @Published var statusMessage: String? = nil

    private let mouseLockService = MouseLockService()

    func setEnabled(_ enabled: Bool) {
        statusMessage = nil

        if enabled {
            // Preflight permissions before attempting to start.
            switch PermissionPreflight.accessibility() {
            case .granted:
                break
            case .needsUserAction(pane: _):
                statusMessage = "StayPut needs Accessibility permission. Enable it in System Settings → Privacy & Security → Accessibility, then quit and relaunch StayPut."
                // Requesting trust may show the standard macOS prompt.
                // We intentionally do NOT auto-open System Settings; the UI provides explicit buttons.
                _ = PermissionService.ensureAccessibilityPermission(prompt: true)
                isEnabled = false
                return
            }

            switch PermissionPreflight.inputMonitoring() {
            case .granted:
                break
            case .needsUserAction(pane: _):
                statusMessage = "StayPut needs Input Monitoring (Listen Event). Enable it in System Settings → Privacy & Security → Input Monitoring, then quit and relaunch StayPut."
                // Important: macOS may not list the app under Input Monitoring until we request access at least once.
                InputMonitoringPermissionService.requestListenEventAccess()
                isEnabled = false
                return
            }

            do {
                try mouseLockService.start()
                isEnabled = true
            } catch {
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

private enum SystemSettingsPane {
    case accessibility
    case inputMonitoring

    var url: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        }
    }

    func open() {
        NSWorkspace.shared.open(url)
    }
}

private enum PermissionState {
    case granted
    case needsUserAction(pane: SystemSettingsPane)
}

/// Coordinate space bridge:
/// - `CGEvent.location` / `CGWarpMouseCursorPosition` use Quartz global coordinates
///   (origin at top-left of the main display; Y increases downward).
/// - `NSScreen.frame` / `visibleFrame` use AppKit screen coordinates
///   (origin at bottom-left of the main display; Y increases upward).
///
/// When combining the two, we must flip Y using the main screen's height.
private enum CoordinateSpace {
    private static var mainScreenHeight: CGFloat {
        (NSScreen.main ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    static func quartzToAppKit(_ point: CGPoint) -> CGPoint {
        let h = mainScreenHeight
        guard h > 0 else { return point }
        return CGPoint(x: point.x, y: h - point.y)
    }

    static func appKitToQuartz(_ point: CGPoint) -> CGPoint {
        let h = mainScreenHeight
        guard h > 0 else { return point }
        return CGPoint(x: point.x, y: h - point.y)
    }
}

private struct PermissionService {
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }

        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Trust state usually updates only after the user enables it in Settings; sometimes needs relaunch.
        return AXIsProcessTrusted()
    }
}

private struct PermissionPreflight {
    static func accessibility() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .needsUserAction(pane: .accessibility)
    }

    static func inputMonitoring() -> PermissionState {
        CGPreflightListenEventAccess() ? .granted : .needsUserAction(pane: .inputMonitoring)
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
        // CoreGraphics API for the TCC "ListenEvent" gate.
        CGRequestListenEventAccess()
        // Fallback: some macOS versions only populate the Input Monitoring list
        // after an IOKit HID access request.
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        // Additional nudge: some systems only attribute/register the app for Input Monitoring
        // after a gated operation is attempted (e.g. creating a HID event tap).
        // This is a best-effort probe; failure is expected when permission is missing.
        let eventsOfInterest: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
        let probeCallback: CGEventTapCallBack = { _, _, event, _ in
            Unmanaged.passUnretained(event)
        }
        if let probeTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: probeCallback,
            userInfo: nil
        ) {
            CFMachPortInvalidate(probeTap)
        }
    }
}

private struct ScreenBoundsService {
    /// Menu Bar Guard (top-only): exclude the top reserved area (menu bar / notch safe area)
    /// but do NOT exclude the dock.
    static func menuBarGuardBounds(for cursorPoint: CGPoint) -> CGRect? {
        let screen = nearestScreen(to: cursorPoint) ?? NSScreen.main
        guard let screen else { return nil }

        // Extra top buffer can make the confined area feel "too low".
        // Keep this at 0 so the boundary tracks the actual menu bar/notch reserved region,
        let overshootBufferTop: CGFloat = 0

        let frame = screen.frame
        let visible = screen.visibleFrame

        let topReserved = max(0, frame.maxY - visible.maxY)
        let maxY = frame.maxY - topReserved - overshootBufferTop

        guard maxY > frame.minY else { return nil }

        return CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: maxY - frame.minY
        )
    }

    /// When the cursor moves fast it can briefly report a location just outside any screen frame.
    /// In that case, pick the nearest screen instead of falling back to `main`, to avoid warping
    /// to the wrong display.
    private static func nearestScreen(to point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        if let containing = screens.first(where: { $0.frame.contains(point) }) {
            return containing
        }

        func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
            let dx: CGFloat
            if point.x < rect.minX {
                dx = rect.minX - point.x
            } else if point.x > rect.maxX {
                dx = point.x - rect.maxX
            } else {
                dx = 0
            }

            let dy: CGFloat
            if point.y < rect.minY {
                dy = rect.minY - point.y
            } else if point.y > rect.maxY {
                dy = point.y - rect.maxY
            } else {
                dy = 0
            }

            return dx * dx + dy * dy
        }

        return screens.min(by: { distanceSquared(from: point, to: $0.frame) < distanceSquared(from: point, to: $1.frame) })
    }
}

private final class MouseLockService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var failsafeTimer: CFRunLoopTimer?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Recursion guard for self-generated warp events.
    private let warpGuardLock = NSLock()
    private var lastWarpTimestampSeconds: Double = 0
    private var lastWarpPoint: CGPoint = .zero

    private let warpGuardWindowSeconds: Double = 0.008
    private let warpGuardDistance: CGFloat = 0.75

    func start() throws {
        if isRunning { return }

        guard PermissionService.ensureAccessibilityPermission(prompt: false) else {
            throw MouseLockError.accessibilityPermissionDenied
        }

        if !InputMonitoringPermissionService.hasListenEventAccess() {
            InputMonitoringPermissionService.requestListenEventAccess()
            // The decision often applies only after relaunch; fail fast with a clear message.
            throw MouseLockError.inputMonitoringPermissionDenied
        }

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

        if let timer = failsafeTimer {
            CFRunLoopTimerInvalidate(timer)
        }
        failsafeTimer = nil
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
        // `CFRunLoopGetCurrent()` is expected to be non-nil on a running thread.
        let rl = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.runLoop = rl

        // Failsafe: if the cursor ever ends up outside bounds (e.g. due to missed events
        // or fast movement), periodically warp it back in.
        installFailsafeTimer(on: rl)

        return nil
    }

    private func installFailsafeTimer(on runLoop: CFRunLoop) {
        guard failsafeTimer == nil else { return }

        let interval: CFTimeInterval = 1.0 / 30.0
        let start = CFAbsoluteTimeGetCurrent() + interval
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, start, interval, 0, 0) { [weak self] _ in
            self?.failsafeEnforceBoundsIfNeeded()
        }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        self.failsafeTimer = timer
    }

    private func failsafeEnforceBoundsIfNeeded() {
        // Only enforce while running.
        guard eventTap != nil else { return }
        guard let event = CGEvent(source: nil) else { return }

        let locQuartz = event.location
        let locAppKit = CoordinateSpace.quartzToAppKit(locQuartz)
        guard let boundsAppKit = ScreenBoundsService.menuBarGuardBounds(for: locAppKit) else { return }
        guard boundsAppKit.width >= 2, boundsAppKit.height >= 2 else { return }

        let clampedAppKit = CGPoint(
            x: clamp(locAppKit.x, min: boundsAppKit.minX, max: boundsAppKit.maxX - 1),
            y: clamp(locAppKit.y, min: boundsAppKit.minY, max: boundsAppKit.maxY - 1)
        )

        if clampedAppKit.x != locAppKit.x || clampedAppKit.y != locAppKit.y {
            let clampedQuartz = CoordinateSpace.appKitToQuartz(clampedAppKit)
            recordWarp(to: clampedQuartz, event: event)
            CGWarpMouseCursorPosition(clampedQuartz)
        }
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

        let locQuartz = event.location
        let locAppKit = CoordinateSpace.quartzToAppKit(locQuartz)

        guard let boundsAppKit = ScreenBoundsService.menuBarGuardBounds(for: locAppKit) else {
            return Unmanaged.passUnretained(event)
        }
        guard boundsAppKit.width >= 2, boundsAppKit.height >= 2 else {
            return Unmanaged.passUnretained(event)
        }

        let clampedAppKit = CGPoint(
            x: clamp(locAppKit.x, min: boundsAppKit.minX, max: boundsAppKit.maxX - 1),
            y: clamp(locAppKit.y, min: boundsAppKit.minY, max: boundsAppKit.maxY - 1)
        )

        if clampedAppKit.x != locAppKit.x || clampedAppKit.y != locAppKit.y {
            let clampedQuartz = CoordinateSpace.appKitToQuartz(clampedAppKit)
            service.recordWarp(to: clampedQuartz, event: event)
            CGWarpMouseCursorPosition(clampedQuartz)
            event.location = clampedQuartz
        }

        return Unmanaged.passUnretained(event)
    }
}

private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, min), max)
}

private enum MouseLockError: LocalizedError {
    case accessibilityPermissionDenied
    case inputMonitoringPermissionDenied
    case eventTapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Missing Accessibility permission. Enable it in System Settings → Privacy & Security → Accessibility, then quit and relaunch StayPut."
        case .inputMonitoringPermissionDenied:
            return "Missing Input Monitoring permission. Enable it in System Settings → Privacy & Security → Input Monitoring, then quit and relaunch StayPut. If StayPut doesn’t appear in the list, quit System Settings and toggle again."
        case .eventTapCreationFailed:
            return "Could not create the event tap. This usually means Accessibility and/or Input Monitoring permissions are missing."
        }
    }
}

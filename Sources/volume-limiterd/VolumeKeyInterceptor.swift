#if os(macOS)

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VolumeLimiterCore

/// Intercepts the hardware "volume up" media key and swallows it once the output
/// is already at the cap.
///
/// This is the only reliable way to stop the audible volume burst on Bluetooth
/// headphones: reactively lowering the volume can't keep up because macOS's own
/// volume-key handler keeps an internal counter that runs away to 100% during
/// rapid presses and drives the device past the cap for a few milliseconds on
/// every press. By consuming the key event before it reaches that handler when we
/// are at the cap, the counter never climbs and there is nothing to burst.
///
/// Requires Accessibility permission (an active event tap that can delete events).
/// Without it the tap can't be created; the daemon keeps working with reactive
/// clamping only and retries periodically so interception turns on automatically
/// once the user grants permission.
final class VolumeKeyInterceptor {
    private let engine: VolumeLimiterEngine
    private let retryInterval: TimeInterval = 3
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var promptedForPermission = false

    init(engine: VolumeLimiterEngine) {
        self.engine = engine
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.runOnDedicatedThread()
        }
        thread.name = "com.volumelimiter.keytap"
        thread.start()
    }

    private func runOnDedicatedThread() {
        if !installTap() {
            promptForAccessibilityIfNeeded()
            let timer = Timer(timeInterval: retryInterval, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.installTap() {
                    timer.invalidate()
                    self.retryTimer = nil
                }
            }
            retryTimer = timer
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
        CFRunLoopRun()
    }

    private func installTap() -> Bool {
        guard tap == nil else {
            return true
        }
        // NX_SYSDEFINED == 14: the event class that carries the volume media keys.
        let mask = CGEventMask(1 << 14)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: volumeKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    private func promptForAccessibilityIfNeeded() {
        guard !promptedForPermission else {
            return
        }
        promptedForPermission = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Called from the event tap callback. Returns the event to pass it through, or
    /// nil to swallow it.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap if a callback is too slow or on certain input;
        // re-enable it so interception keeps working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0x0000_FF00) >> 8
        let isKeyDown = keyState == 0x0A // 0x0A down (incl. auto-repeat), 0x0B up

        // NX_KEYTYPE_SOUND_UP == 0. Only act on key-down/repeat; releases are
        // harmless and pass through untouched.
        guard keyCode == 0, isKeyDown else {
            return Unmanaged.passUnretained(event)
        }

        if engine.shouldSwallowVolumeUp() {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

private func volumeKeyTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let interceptor = Unmanaged<VolumeKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    return interceptor.handle(type: type, event: event)
}

#endif

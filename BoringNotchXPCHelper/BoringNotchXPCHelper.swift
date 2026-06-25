//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import OSLog
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }

    // MARK: - Scroll Reverser
    //
    // Modeled after pilotmoon/Scroll-Reverser's proven approach:
    //
    // 1. A **passive** event tap listens for NSEventMaskGesture to detect
    //    trackpad finger touches (without interfering with gestures).
    // 2. An **active** event tap intercepts NSEventMaskScrollWheel to
    //    modify scroll deltas.
    // 3. Touch timing heuristics distinguish mouse from trackpad even
    //    for continuous-scrolling devices like Magic Mouse.
    //
    // The scroll reverser uses a dedicated thread with its own CFRunLoop.
    // XPC services use GCD internally — CFRunLoopGetMain() is NOT driven,
    // so adding sources there does nothing.  We spin up our own thread
    // and run the loop there.
    //
    // State is kept in statics so it survives across XPC connections
    // (each connection creates a new BoringNotchXPCHelper instance).
    
    // Event tap ports and run loop
    private static var scrollEventTap: CFMachPort?       // active tap (scroll wheel)
    private static var gestureTap: CFMachPort?           // passive tap (gesture/touch)
    private static var scrollRunLoopSource: CFRunLoopSource?
    private static var gestureRunLoopSource: CFRunLoopSource?
    private static var scrollRunLoop: CFRunLoop?
    private static var scrollThread: Thread?
    
    // Touch-tracking state for device detection (accessed only from the
    // dedicated scroll thread, so no locking needed).
    private static var lastTouchTime: UInt64 = 0
    private static var touching: Int = 0
    private static var lastSource: Int = 0 // 0 = mouse, 1 = trackpad
    
    private static let sourceMouseValue = 0
    private static let sourceTrackpadValue = 1
    
    /// Nanosecond timestamp via mach_absolute_time.
    private static func nanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)
    }

    @objc func startScrollReverser(with reply: @escaping (Bool) -> Void) {
        let logger = Logger(subsystem: "com.hugo.boringNotch", category: "ScrollReverser")

        // If already running, just reply success
        if BoringNotchXPCHelper.scrollEventTap != nil {
            logger.info("Scroll reverser already running.")
            reply(true)
            return
        }

        // Check Input Monitoring permission (TCC)
        let preflight = CGPreflightListenEventAccess()
        if !preflight {
            logger.warning("Input Monitoring not authorized, prompting user...")
            // This will prompt the user to go to System Settings
            _ = CGRequestListenEventAccess()
            logger.error("Input Monitoring permission required. Please enable it in System Settings > Privacy & Security > Input Monitoring, then try again.")
            reply(false)
            return
        }

        logger.info("Input Monitoring authorized, creating scroll event taps on dedicated thread.")

        // Create event taps on a dedicated thread with its own run loop
        let thread = Thread {
            let threadLogger = Logger(subsystem: "com.hugo.boringNotch", category: "ScrollReverser")
            
            // ── Passive gesture tap ──
            // Listens for gesture events (trackpad finger touches) without
            // modifying them. Using a passive/listen-only tap avoids
            // interfering with "shake to locate cursor", notification
            // center swipe, and authorization dialogs.
            let gestureMask = CGEventMask(1 << 29) // NSEventTypeGesture = 29
            let gTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: gestureMask,
                callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                    // Any gesture event (type 29) implies trackpad activity.
                    // We can't use NSEvent/AppKit in the XPC helper, so we
                    // simply record the timestamp. The scroll callback uses
                    // this to distinguish trackpad from mouse.
                    BoringNotchXPCHelper.lastTouchTime = BoringNotchXPCHelper.nanoseconds()
                    BoringNotchXPCHelper.touching = max(BoringNotchXPCHelper.touching, 2)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: nil
            )
            
            // ── Active scroll wheel tap ──
            let scrollMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            let sTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .defaultTap,
                eventsOfInterest: scrollMask,
                callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        // Re-enable taps
                        if let tap = BoringNotchXPCHelper.scrollEventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        if let tap = BoringNotchXPCHelper.gestureTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        return Unmanaged.passUnretained(event)
                    }

                    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
                    
                    // ── Determine event source (mouse vs trackpad) ──
                    // Following pilotmoon/Scroll-Reverser's heuristics:
                    
                    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                    let now = BoringNotchXPCHelper.nanoseconds()
                    let touchElapsed = now - BoringNotchXPCHelper.lastTouchTime
                    let currentTouching = BoringNotchXPCHelper.touching
                    BoringNotchXPCHelper.touching = 0
                    
                    // Momentum phase detection via CGEvent field.
                    // scrollWheelEventMomentumPhase: 0 = no momentum (normal),
                    // non-zero = momentum scrolling is active.
                    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                    let isNormalPhase = (momentumPhase == 0)
                    
                    let millisecond: UInt64 = 1_000_000
                    
                    let source: Int = {
                        // Non-continuous events are always from a classic mouse
                        if !isContinuous {
                            return BoringNotchXPCHelper.sourceMouseValue
                        }
                        
                        // Recent multi-finger touch → trackpad
                        if currentTouching >= 2 && touchElapsed < (millisecond * 222) {
                            return BoringNotchXPCHelper.sourceTrackpadValue
                        }
                        
                        // No momentum phase and long time since touch → mouse
                        // (catches Magic Mouse which is continuous but has no finger touches)
                        if isNormalPhase && touchElapsed > (millisecond * 333) {
                            return BoringNotchXPCHelper.sourceMouseValue
                        }
                        
                        // Not enough info — keep the previous source
                        return BoringNotchXPCHelper.lastSource
                    }()
                    BoringNotchXPCHelper.lastSource = source
                    
                    // Only invert mouse scrolling
                    guard source == BoringNotchXPCHelper.sourceMouseValue else {
                        return Unmanaged.passUnretained(event)
                    }

                    // ── Invert scroll deltas ──
                    // Important: set DeltaAxis FIRST, then PointDelta.
                    // Setting DeltaAxis causes macOS to internally recalculate
                    // PointDelta (8x multiplier) and FixedPtDelta (1x), so we
                    // must set those after.
                    
                    let delta1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                    let delta2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                    
                    // Vertical
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta1)
                    
                    // For non-discrete (continuous mouse), also set point and fixed-point fields
                    if isContinuous {
                        let pt1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pt1)
                        let fx1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fx1)
                    }
                    
                    // Horizontal
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta2)
                    if isContinuous {
                        let pt2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
                        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pt2)
                        let fx2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
                        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fx2)
                    }

                    return Unmanaged.passUnretained(event)
                },
                userInfo: nil
            )

            guard let scrollTap = sTap else {
                threadLogger.error("Failed to create scroll event tap on dedicated thread. This usually means Input Monitoring permission is not granted or the app doesn't have the necessary entitlements.")
                return
            }

            BoringNotchXPCHelper.scrollEventTap = scrollTap
            let scrollSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, scrollTap, 0)
            BoringNotchXPCHelper.scrollRunLoopSource = scrollSource
            BoringNotchXPCHelper.scrollRunLoop = CFRunLoopGetCurrent()
            
            if let scrollSource = scrollSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), scrollSource, .commonModes)
            }
            CGEvent.tapEnable(tap: scrollTap, enable: true)
            
            // Install gesture tap if available
            if let gestureTap = gTap {
                BoringNotchXPCHelper.gestureTap = gestureTap
                let gestureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gestureTap, 0)
                BoringNotchXPCHelper.gestureRunLoopSource = gestureSource
                if let gestureSource = gestureSource {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), gestureSource, .commonModes)
                }
                CGEvent.tapEnable(tap: gestureTap, enable: true)
                threadLogger.info("Gesture tap installed for trackpad detection.")
            } else {
                threadLogger.warning("Could not create gesture tap — falling back to continuous-only detection.")
            }

            threadLogger.info("Scroll event tap installed and enabled on dedicated run loop.")

            // Run the loop — this blocks until the loop is stopped
            CFRunLoopRun()
            threadLogger.info("Scroll reverser run loop exited.")
        }

        thread.name = "com.hugo.boringNotch.scrollReverser"
        thread.qualityOfService = .init(rawValue: 33) ?? .default // QOS_CLASS_USER_INTERACTIVE
        BoringNotchXPCHelper.scrollThread = thread
        thread.start()

        // Give the thread a moment to create the tap, then reply
        // Increased timeout to 1 second to handle slower systems
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if BoringNotchXPCHelper.scrollEventTap != nil {
                logger.info("Scroll reverser started successfully.")
                reply(true)
            } else {
                logger.error("Scroll reverser failed to start within timeout. Check that Input Monitoring permission is granted and the event tap was created successfully.")
                reply(false)
            }
        }
    }

    @objc func requestInputMonitoringAuthorization(with reply: @escaping (Bool) -> Void) {
        let logger = Logger(subsystem: "com.hugo.boringNotch", category: "InputMonitoring")
        let preflight = CGPreflightListenEventAccess()
        if preflight {
            logger.info("Input Monitoring already authorized.")
            reply(true)
            return
        }
        logger.info("Requesting Input Monitoring permission…")
        let granted = CGRequestListenEventAccess()
        if granted {
            logger.info("Input Monitoring permission granted.")
        } else {
            logger.warning("Input Monitoring permission not yet granted — user must allow in System Settings.")
        }
        reply(granted)
    }

    @objc func stopScrollReverser(with reply: @escaping (Bool) -> Void) {
        let logger = Logger(subsystem: "com.hugo.boringNotch", category: "ScrollReverser")
        
        // Disable taps
        if let tap = BoringNotchXPCHelper.scrollEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let tap = BoringNotchXPCHelper.gestureTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        // Stop the run loop
        if let rl = BoringNotchXPCHelper.scrollRunLoop {
            CFRunLoopStop(rl)
        }
        
        // Remove sources
        if let src = BoringNotchXPCHelper.scrollRunLoopSource, let rl = BoringNotchXPCHelper.scrollRunLoop {
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        if let src = BoringNotchXPCHelper.gestureRunLoopSource, let rl = BoringNotchXPCHelper.scrollRunLoop {
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        
        // Clear all state
        BoringNotchXPCHelper.scrollEventTap = nil
        BoringNotchXPCHelper.gestureTap = nil
        BoringNotchXPCHelper.scrollRunLoopSource = nil
        BoringNotchXPCHelper.gestureRunLoopSource = nil
        BoringNotchXPCHelper.scrollRunLoop = nil
        BoringNotchXPCHelper.scrollThread = nil
        BoringNotchXPCHelper.lastTouchTime = 0
        BoringNotchXPCHelper.touching = 0
        BoringNotchXPCHelper.lastSource = 0
        
        logger.info("Scroll reverser stopped.")
        reply(true)
    }
}

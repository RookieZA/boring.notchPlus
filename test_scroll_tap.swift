#!/usr/bin/env swift
import CoreGraphics
import Foundation

print("=== Scroll Tap Diagnostic ===")
print("CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())")
print("CGPreflightPostEventAccess: \(CGPreflightPostEventAccess())")

let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("[TAP] Re-enabling tap (disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"))")
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }
        
        let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        
        print("[SCROLL] delta1=\(d1) delta2=\(d2) isContinuous=\(isContinuous)")
        
        // Invert
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -d1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -d2)
        
        // Also invert the fixed-point fields
        for rawField: UInt32 in [93, 94, 96, 97] {
            if let field = CGEventField(rawValue: rawField) {
                let val = event.getIntegerValueField(field)
                event.setIntegerValueField(field, value: -val)
            }
        }
        
        print("[SCROLL] -> INVERTED delta1=\(-d1) delta2=\(-d2)")
        return Unmanaged.passRetained(event)
    },
    userInfo: nil
)

if let tap = tap {
    print("✅ Event tap created successfully!")
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("✅ Event tap enabled. Scroll your mouse now — press Ctrl+C to stop.")
    print("   (Scrolling should be inverted)")
    CFRunLoopRun()
} else {
    print("❌ Failed to create event tap!")
    print("   Make sure this terminal has Input Monitoring permission.")
    print("   System Settings → Privacy & Security → Input Monitoring → add Terminal")
}

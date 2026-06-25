//
//  ScrollDirectionManager.swift
//  boringNotch
//
//  Created via boring.notch contribution.
//

import Foundation
import AppKit
import ApplicationServices
import Defaults
import OSLog

/// Intercepts scroll-wheel events system-wide and reverses the scroll
/// direction so that a traditional (non-natural) mouse scroll feel is
/// achieved even when macOS "Natural Scrolling" is turned on.
///
/// Modeled after `MediaKeyInterceptor` — uses a `CGEvent` tap that
/// requires Accessibility authorization.
final class ScrollDirectionManager {
    static let shared = ScrollDirectionManager()
    private let logger = Logger(subsystem: "com.hugo.boringNotch", category: "ScrollDirection")

    private var isRunning = false

    private init() {}

    // MARK: - Lifecycle

    func start(promptIfNeeded: Bool = true) async {
        guard !isRunning else {
            logger.info("Already running, skipping start.")
            return
        }
        guard Defaults[.enableNormalScrolling] else {
            logger.info("Setting disabled, skipping start.")
            return
        }

        logger.info("Starting scroll reverser via XPC helper…")

        // Delegate directly to the unsandboxed XPC helper.
        // The helper handles Input Monitoring permission checks internally.
        let success = await XPCHelperClient.shared.startScrollReverser()
        if success {
            isRunning = true
            logger.info("Scroll reverser started in XPC helper.")
        } else {
            logger.error("Failed to start scroll reverser in XPC helper.")
            
            // Show alert to user
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Input Monitoring Permission Required"
                alert.informativeText = "To use mouse scroll inversion, please enable Input Monitoring permission:\n\n1. Open System Settings\n2. Go to Privacy & Security → Input Monitoring\n3. Enable access for BoringNotch or BoringNotchXPCHelper\n4. Try enabling the feature again"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings to Input Monitoring
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            
            // Disable the setting since it failed
            Defaults[.enableNormalScrolling] = false
        }
    }

    func stop() {
        guard isRunning else { return }
        Task {
            let success = await XPCHelperClient.shared.stopScrollReverser()
            if success {
                isRunning = false
                logger.info("Scroll reverser stopped in XPC helper.")
            }
        }
    }
}

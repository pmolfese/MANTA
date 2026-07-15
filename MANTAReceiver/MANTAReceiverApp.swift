import AppKit
import SwiftUI

private enum MANTAReceiverBranding {
    static let applicationName = "MANTA Receiver"

    static let applicationIcon: NSImage? = {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: iconURL)
    }()
}

final class MANTAReceiverAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let icon = MANTAReceiverBranding.applicationIcon else {
            return
        }

        NSApplication.shared.applicationIconImage = icon
    }

}

// Application Support is no longer used as scratch space: every capture lives
// entirely in its own package folder, wherever the user keeps it, and edits
// happen in place there. Nothing is written to Application Support during
// normal operation, so there is nothing to wipe on quit. Application Support
// is reserved for state that should persist across every capture - e.g. a
// future trained CoreML model - which must survive app quits, not be erased
// by them.

@main
struct MANTAReceiverApp: App {
    @NSApplicationDelegateAdaptor(MANTAReceiverAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MANTA Receiver") {
            ReceiverContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(MANTAReceiverBranding.applicationName)") {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [
                        .applicationName: MANTAReceiverBranding.applicationName
                    ]
                    if let icon = MANTAReceiverBranding.applicationIcon {
                        options[.applicationIcon] = icon
                    }
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }
        }
    }
}

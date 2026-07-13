import AppKit
import SwiftUI

final class MANTAReceiverAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else {
            return
        }

        NSApplication.shared.applicationIconImage = icon
    }
}

@main
struct MANTAReceiverApp: App {
    @NSApplicationDelegateAdaptor(MANTAReceiverAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MANTA Receiver") {
            ReceiverContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

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

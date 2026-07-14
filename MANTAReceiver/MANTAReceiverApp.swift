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

    func applicationWillTerminate(_ notification: Notification) {
        do {
            try MANTAReceiverApplicationSupport.removeAll()
        } catch {
            NSLog("MANTA Receiver could not clear Application Support: %@", error.localizedDescription)
        }
    }
}

nonisolated enum MANTAReceiverApplicationSupport {
    static let directoryName = "MANTA Receiver"

    static func removeAll(fileManager: FileManager = .default) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
            .standardizedFileURL
        let receiverDirectory = applicationSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL

        // Keep the deletion rigidly scoped to this application's own support
        // directory. Never remove the shared Application Support directory.
        guard receiverDirectory.deletingLastPathComponent() == applicationSupport,
              receiverDirectory.lastPathComponent == directoryName,
              fileManager.fileExists(atPath: receiverDirectory.path) else { return }
        try fileManager.removeItem(at: receiverDirectory)
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

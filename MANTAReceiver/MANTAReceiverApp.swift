import SwiftUI

@main
struct MANTAReceiverApp: App {
    var body: some Scene {
        WindowGroup("MANTA Receiver") {
            ReceiverContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

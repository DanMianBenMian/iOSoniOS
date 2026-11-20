import SwiftUI

@main
struct iOSoniOSApp: App {
    init() {
        // Must be first: RyLog takes over stdout/stderr so the engine's and the
        // guest's fprintf output lands in iosonios.log from the very first line.
        RyLog.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

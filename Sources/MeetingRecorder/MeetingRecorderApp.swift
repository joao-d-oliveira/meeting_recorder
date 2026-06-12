import SwiftUI

@main
struct MeetingRecorderApp: App {
    @StateObject private var model = AppModel()

    init() {
        // FFmpegProcess.writeStdin relies on SIGPIPE being ignored: a write to a
        // dead ffmpeg's pipe then surfaces as a catchable error, not process death.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("Meeting Recorder") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    // Needed when launched via `swift run` (no bundle): become a regular app.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
    }
}

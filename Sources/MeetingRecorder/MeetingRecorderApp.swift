import Combine
import SwiftUI

/// Owns the model so quit handling can see the recording state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var stateObserver: AnyCancellable?
    private var quitTimeout: DispatchWorkItem?

    // Closing the window quits, so it goes through the same confirmation as Cmd-Q
    // instead of leaving a windowless recording running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A repeated quit request while we are already waiting on ffmpeg.
        if stateObserver != nil { return .terminateLater }

        if case .recording = model.controller.state {
            guard confirmStopAndQuit() else { return .terminateCancel }
            model.stopRecording()
        }
        // Re-read the state: ffmpeg can exit while the modal alert is up.
        guard case .stopping = model.controller.state else { return .terminateNow }

        waitForStopThenReply()
        return .terminateLater
    }

    private func confirmStopAndQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A recording is in progress. Stop and save it before quitting?"
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func waitForStopThenReply() {
        // $state emits in willSet; hopping to the next main-queue turn lets the
        // controller finish its state change before termination begins.
        stateObserver = model.controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .stopping = state { return }
                self?.replyToTerminate()
            }
        // The controller SIGKILLs ffmpeg at 10 s; this only covers a missing exit callback.
        let timeout = DispatchWorkItem { [weak self] in self?.replyToTerminate() }
        quitTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func replyToTerminate() {
        guard stateObserver != nil else { return }  // already replied
        stateObserver = nil
        quitTimeout?.cancel()
        quitTimeout = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // FFmpegProcess.writeStdin relies on SIGPIPE being ignored: a write to a
        // dead ffmpeg's pipe then surfaces as a catchable error, not process death.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("Meeting Recorder") {
            ContentView()
                .environmentObject(appDelegate.model)
                .onAppear {
                    // Needed when launched via `swift run` (no bundle): become a regular app.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
    }
}

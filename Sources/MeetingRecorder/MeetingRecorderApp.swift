import Combine
import SwiftUI

/// Owns the model so quit handling can see the recording and transcription state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var stateObserver: AnyCancellable?
    private var quitTimeout: DispatchWorkItem?

    // Closing the window quits, so it goes through the same confirmation as Cmd-Q. While a
    // recording runs the window cannot be closed at all (`WindowCloseLock`), so declining
    // the confirmation never leaves a windowless app that is still recording. A running
    // transcription does not lock the window; see `restoreWindowIfNeeded`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A repeated quit request while we are already waiting on ffmpeg or the pipeline.
        if stateObserver != nil { return .terminateLater }

        var recordingInProgress = false
        if case .recording = model.controller.state { recordingInProgress = true }
        if recordingInProgress || model.isTranscribing {
            guard confirmQuit(recording: recordingInProgress, transcribing: model.isTranscribing) else {
                restoreWindowIfNeeded()
                return .terminateCancel
            }
        }

        // From here on the app is quitting: stopping the recording must not auto-start a
        // transcription of the file it saves.
        model.prepareForQuit()
        // Re-read the state: a process can exit while the modal alert is up.
        if case .recording = model.controller.state { model.stopRecording() }
        model.cancelTranscription()

        var recordingStopping = false
        if case .stopping = model.controller.state { recordingStopping = true }
        guard recordingStopping || model.isTranscribing else { return .terminateNow }

        // ffmpeg is SIGKILLed at 10 s; the pipeline gets SIGINT, then SIGKILL after 4 s.
        waitForStopThenReply(timeout: recordingStopping ? 12 : 6)
        return .terminateLater
    }

    /// Declining the quit that closing the window started (a transcription is running) leaves
    /// the app without a window. Brings one back: an existing one if AppKit kept it, otherwise
    /// a new one through the File > New Window action of the WindowGroup. Best effort; the Dock
    /// icon reopens the window as well. Does nothing if a window is there (Cmd-Q, Dock > Quit).
    private func restoreWindowIfNeeded() {
        DispatchQueue.main.async {
            let candidates = NSApp.windows.filter { $0.canBecomeMain }
            if candidates.contains(where: { $0.isVisible || $0.isMiniaturized }) { return }
            if let existing = candidates.first {
                existing.makeKeyAndOrderFront(nil)
            } else {
                NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func confirmQuit(recording: Bool, transcribing: Bool) -> Bool {
        let alert = NSAlert()
        switch (recording, transcribing) {
        case (true, true):
            alert.messageText = "A recording and a transcription are in progress. "
                + "Stop and save the recording, cancel the transcription, and quit?"
            alert.addButton(withTitle: "Stop, Cancel & Quit")
        case (true, false):
            alert.messageText = "A recording is in progress. Stop and save it before quitting?"
            alert.addButton(withTitle: "Stop & Quit")
        default:
            alert.messageText = "A transcription is in progress. Cancel it and quit?"
            alert.informativeText = "No transcript is written for an unfinished run."
            alert.addButton(withTitle: "Cancel Transcription & Quit")
        }
        alert.addButton(withTitle: "Don't Quit")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func waitForStopThenReply(timeout: TimeInterval) {
        // $state emits in willSet; hopping to the next main-queue turn lets the
        // controllers finish their state changes before termination begins.
        stateObserver = Publishers.CombineLatest(model.controller.$state, model.transcription.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.quitStateChanged() }
        armQuitTimeout(timeout)
    }

    /// Replies to the pending termination once nothing is left to wait for. Reads the settled
    /// states (the values the publishers emitted may be stale after the hop).
    private func quitStateChanged() {
        switch model.controller.state {
        case .stopping:
            return
        case .recording:
            // Not expected: nothing can start a recording once the user agreed to quit. But
            // replying now would orphan ffmpeg and record forever, so stop it and wait again
            // (ffmpeg is SIGKILLed at 10 s).
            model.stopRecording()
            armQuitTimeout(12)
            return
        case .idle, .saved, .failed:
            break
        }
        if model.isTranscribing { return }
        replyToTerminate()
    }

    /// Only covers a missing exit callback; both controllers escalate to SIGKILL themselves.
    private func armQuitTimeout(_ seconds: TimeInterval) {
        quitTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.replyToTerminate() }
        quitTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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

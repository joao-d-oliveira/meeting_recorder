import Combine
import SwiftUI

/// Owns the model so quit handling can see the recording and transcription state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var stateObserver: AnyCancellable?
    private var quitTimeout: DispatchWorkItem?

    // Closing the window quits, so it goes through the same confirmation as Cmd-Q
    // instead of leaving a windowless recording running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A repeated quit request while we are already waiting on ffmpeg or the pipeline.
        if stateObserver != nil { return .terminateLater }

        var recordingInProgress = false
        if case .recording = model.controller.state { recordingInProgress = true }
        if recordingInProgress || model.isTranscribing {
            guard confirmQuit(recording: recordingInProgress, transcribing: model.isTranscribing) else {
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
            .sink { [weak self] recording, transcription in
                if case .stopping = recording { return }
                if case .running = transcription { return }
                self?.replyToTerminate()
            }
        // Only covers a missing exit callback; both controllers escalate to SIGKILL themselves.
        let work = DispatchWorkItem { [weak self] in self?.replyToTerminate() }
        quitTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
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

import AppKit
import SwiftUI

@main
@MainActor
struct MotionPhotoBridgeApp: App {
    @NSApplicationDelegateAdaptor(MotionPhotoBridgeAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MotionPhotoBridge") {
            ContentView(model: model)
                .onAppear { appDelegate.attach(model) }
                .frame(minWidth: 860, minHeight: 650)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photos…") { model.chooseFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isBusy)
                Button("Add Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
            }
            CommandMenu("Convert") {
                Button("Convert Queued Photos") { model.startConversion() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.pendingCount == 0)
                Button("Stop Conversion") { model.cancelConversion() }
                    .disabled(!model.isConverting)
                Divider()
                Button("Choose Export Folder…") { model.chooseOutputDirectory() }
                    .disabled(model.isBusy)
            }
        }
    }
}

@MainActor
final class MotionPhotoBridgeAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var pendingOpenURLs: [URL] = []
    private var waitingToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func attach(_ model: AppModel) {
        self.model = model
        if !pendingOpenURLs.isEmpty {
            model.enqueueURLs(pendingOpenURLs)
            pendingOpenURLs.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.enqueueURLs(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        if waitingToTerminate { return .terminateLater }

        let alert = NSAlert()
        alert.messageText = "MotionPhotoBridge is still working"
        alert.informativeText = "MotionPhotoBridge can stop after the current operation is safely finished. Completed exports will be kept."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // The nested alert run loop may have allowed the last operation to finish.
        guard model.isBusy else { return .terminateNow }

        waitingToTerminate = true
        model.onBecomingIdle = { [weak self] in
            guard self?.waitingToTerminate == true else { return }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        model.cancelConversion()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.releaseSecurityScopes()
    }
}

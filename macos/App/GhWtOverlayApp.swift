// GhWtOverlayApp.swift — minimal SwiftUI host app for the FSKit System
// Extension. macOS requires the extension to live inside an app bundle;
// this app does nothing except request that the extension be activated
// the first time the user launches it.

import SwiftUI
import SystemExtensions

@main
struct GhWtOverlayApp: App {
    @StateObject private var activator = ExtensionActivator()
    var body: some Scene {
        WindowGroup {
            ContentView(activator: activator)
                .frame(minWidth: 420, minHeight: 220)
        }
    }
}

struct ContentView: View {
    @ObservedObject var activator: ExtensionActivator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("gh-wt overlay").font(.title2).bold()
            Text("FSKit System Extension that powers `gh wt` on macOS.")
                .foregroundStyle(.secondary)
            Divider()
            Text(activator.statusLine).monospaced()
            HStack {
                Button("Activate extension") { activator.activate() }
                Button("Open System Settings") { activator.openSettings() }
            }
            Spacer()
        }
        .padding(20)
        .onAppear { activator.activate() }
    }
}

final class ExtensionActivator: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var statusLine: String = "idle"

    private let bundleID = "com.github.gh-wt.overlay"

    func activate() {
        statusLine = "requesting activation…"
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleID, queue: .main
        )
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        statusLine = "needs user approval — open System Settings → Login Items & Extensions → File System Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        statusLine = "result: \(result)"
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        statusLine = "failed: \(error.localizedDescription)"
    }
}

#if canImport(AppKit)
import AppKit
#endif

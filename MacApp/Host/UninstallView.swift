import AppKit
import SwiftUI

@MainActor struct UninstallView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prepare to Uninstall MyDrive").font(.title2.weight(.semibold))
            Text("Disconnect all drives and remove clean local downloads. NAS originals are kept. Pending edits and upload recovery data are retained for you to review.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.preparingUninstall {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.uninstall.currentDrive.map { "Disconnecting \($0)…" } ?? "Checking Finder drives…")
                }
            } else if model.uninstall.ready {
                Label("All drives are disconnected. Ready to quit.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Finder will show the app so you can move it to the Trash. Dragging the app to the Trash alone does not guarantee removal of local downloads.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.uninstall.issues.isEmpty {
                ScrollView {
                    Text(model.uninstall.issues.joined(separator: "\n\n"))
                        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
            if !model.retainedWork.isEmpty {
                Text("Retained Local Work").font(.headline)
                List(model.retainedWork, id: \.self) { location in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.path).font(.caption).textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                    }.padding(.vertical, 4)
                }.frame(height: 140)
            }
            HStack {
                if model.preparingUninstall {
                    Button("Stop") { operation?.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.uninstall.ready {
                    Button("Quit and Show App in Finder", action: quitAndReveal)
                        .keyboardShortcut(.defaultAction).disabled(model.busy)
                } else {
                    Button("Disconnect All & Remove Downloads", role: .destructive, action: prepare)
                        .disabled(model.busy || model.drives.contains(where: \.busy)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(model.preparingUninstall)
        .onDisappear { operation?.cancel(); operation = nil }
    }

    private func prepare() {
        guard !model.busy, operation == nil else { return }
        operation = Task {
            await model.prepareForUninstall()
            operation = nil
        }
    }

    private func quitAndReveal() {
        guard model.uninstall.ready, !model.busy else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApplication.shared.terminate(nil)
    }
}

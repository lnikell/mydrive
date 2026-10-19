import AppKit
import SwiftUI

/// The same disconnect-everything flow serves Uninstall MyDrive… and
/// Settings › Advanced › Remove all mounts. Only uninstall offers to quit.
enum RemovalMode: String, Identifiable {
    case uninstall, removeAll
    var id: String { rawValue }
}

@MainActor struct UninstallView: View {
    @Bindable var model: AppModel
    var mode: RemovalMode = .uninstall
    let requestQuit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(icon: mode == .uninstall ? .trash : .eject, size: 40, radius: 10,
                         fill: Color(nsColor: Palette.hex(0xFF3B30, 0.12)), tint: Palette.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .uninstall ? "Prepare to Uninstall MyDrive" : "Remove All Mounts")
                        .font(Typography.title3).foregroundStyle(Palette.primary)
                    Text("NAS originals are kept").font(Typography.callout).foregroundStyle(Palette.secondary)
                }
            }
            Text("Disconnect all drives and remove clean local downloads. NAS originals are kept. Pending edits and upload recovery data are retained for you to review.")
                .font(Typography.body).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            if model.preparingUninstall {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.uninstall.currentDrive.map { "Disconnecting \($0)…" } ?? "Checking Finder drives…")
                        .font(Typography.body).foregroundStyle(Palette.primary)
                }
            } else if model.uninstall.ready {
                Label {
                    Text(mode == .uninstall ? "All drives are disconnected. Ready to quit." : "All drives are disconnected.")
                } icon: {
                    Icon(.check, size: 15)
                }
                .font(Typography.bodyMedium)
                .foregroundStyle(Palette.green)
                if mode == .uninstall {
                    Text("Finder will show the app so you can move it to the Trash. Dragging the app to the Trash alone does not guarantee removal of local downloads.")
                        .font(Typography.callout).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.uninstall.issues.isEmpty {
                ScrollView {
                    Text(model.uninstall.issues.joined(separator: "\n\n"))
                        .font(Typography.callout).foregroundStyle(Palette.primary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.subtle))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1))
            }
            if !model.retainedWork.isEmpty {
                Text("Unsynced changes saved on this Mac").font(Typography.headline).foregroundStyle(Palette.primary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.retainedWork, id: \.self) { location in
                            HStack(spacing: 10) {
                                Text(location.path).font(Typography.mono).foregroundStyle(Palette.primary)
                                    .textSelection(.enabled).lineLimit(2)
                                Spacer(minLength: 8)
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                                    .buttonStyle(CardButtonStyle())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Hairline() }
                        }
                    }
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.subtle))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1))
            }
            HStack(spacing: 8) {
                if model.preparingUninstall {
                    Button("Stop") { operation?.cancel() }
                        .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(model.uninstall.ready && mode == .removeAll ? "Done" : "Close") { dismiss() }
                        .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.uninstall.ready && mode == .uninstall {
                    Button("Quit and Show App in Finder", action: quitAndReveal)
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction).disabled(model.busy)
                } else if !model.uninstall.ready {
                    Button("Disconnect All & Remove Downloads", role: .destructive, action: prepare)
                        .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12, role: .destructive))
                        .disabled(model.busy || model.drives.contains(where: \.busy)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(Palette.window)
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
        requestQuit()
        dismiss()
    }
}

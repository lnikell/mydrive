import AppKit
import SwiftUI

private struct ConnectionSheetRequest: Identifiable {
    let id = UUID()
    let settings: ConnectionSettings
    let drive: DriveModel?
}

@MainActor struct ConnectionsView: View {
    @Bindable var model: AppModel
    @Binding var addRequested: Bool
    @Binding var uninstallRequested: Bool
    @State private var sheet: ConnectionSheetRequest?
    @State private var removingDrive: DriveModel?
    @State private var showingLoadIssues = false
    @State private var showingRetainedWork = false
    @State private var showingUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            if model.drives.isEmpty {
                ContentUnavailableView {
                    Label("Your NAS, in Finder", systemImage: "externaldrive.badge.wifi")
                } description: {
                    Text("Add a drive to browse its files and keep what you need on this Mac.")
                } actions: {
                    Button("Add Drive…", action: presentAdd)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.drives) { drive in
                        ConnectionRow(drive: drive, reconnect: {
                            sheet = ConnectionSheetRequest(settings: drive.settings, drive: drive)
                        }, disconnect: { removingDrive = drive }, perform: { action in
                            Task { await model.perform(action, on: drive) }
                        })
                    }
                }
                .listStyle(.inset)
                .disabled(model.busy)
            }
            if !model.status.isEmpty || !model.loadIssues.isEmpty || !model.retainedWork.isEmpty { footer }
        }
        .navigationTitle("MyDrive")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Drive", systemImage: "plus", action: presentAdd)
                    .disabled(model.busy)
                    .help("Connect another NAS share")
            }
        }
        .task {
            await model.startup()
            presentRequestedAdd()
            presentRequestedUninstall()
        }
        .onChange(of: addRequested) { _, _ in presentRequestedAdd() }
        .onChange(of: uninstallRequested) { _, _ in presentRequestedUninstall() }
        .onChange(of: model.busy) { _, busy in if !busy { presentRequestedUninstall() } }
        .onChange(of: showingLoadIssues) { _, showing in if !showing { presentRequestedUninstall() } }
        .onChange(of: removingDrive?.id) { _, id in if id == nil { presentRequestedUninstall() } }
        .sheet(item: $sheet, onDismiss: presentRequestedUninstall) { request in
            DriveConnectionSheet(model: model, settings: request.settings, drive: request.drive)
        }
        .sheet(isPresented: $showingRetainedWork, onDismiss: presentRequestedUninstall) { RetainedWorkView(locations: model.retainedWork) }
        .sheet(isPresented: $showingUninstall) { UninstallView(model: model) }
        .confirmationDialog(
            "Disconnect \(removingDrive?.name ?? "this drive") and remove local downloads?",
            isPresented: Binding(get: { removingDrive != nil }, set: { if !$0 { removingDrive = nil } }),
            titleVisibility: .visible
        ) {
            if let drive = removingDrive {
                Button("Disconnect & Remove Local Downloads", role: .destructive) {
                    Task { await model.remove(drive) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files on the NAS are kept. Clean local downloads are removed. Pending edits and upload recovery data are preserved, with an option to show them in Finder.")
        }
        .alert("Saved Drive Issues", isPresented: $showingLoadIssues) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.loadIssues.map(\.message).joined(separator: "\n\n"))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !model.status.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).textSelection(.enabled)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if !model.retainedWork.isEmpty {
                    Button("Show Retained Work…") { showingRetainedWork = true }
                        .font(.caption)
                }
                Spacer(minLength: 4)
                if !model.loadIssues.isEmpty {
                    Button("Saved Drive Issues…") { showingLoadIssues = true }
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.bar)
    }

    private func presentAdd() {
        guard !model.busy, !showingUninstall, sheet == nil, removingDrive == nil else { return }
        sheet = ConnectionSheetRequest(settings: model.makeDraft(), drive: nil)
    }

    private func presentRequestedAdd() {
        guard addRequested, !model.busy else { return }
        addRequested = false
        presentAdd()
    }

    private func presentRequestedUninstall() {
        guard uninstallRequested, !model.busy, sheet == nil, removingDrive == nil,
              !showingRetainedWork, !showingLoadIssues else { return }
        uninstallRequested = false
        showingUninstall = true
    }
}

@MainActor private struct RetainedWorkView: View {
    let locations: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Retained Local Work").font(.title2.weight(.semibold))
            Text("These files were kept when a drive was disconnected. Review them before removing anything you still need.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(locations, id: \.self) { location in
                VStack(alignment: .leading, spacing: 6) {
                    Text(location.path).font(.callout).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                }.padding(.vertical, 6)
            }.frame(height: 220)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480)
    }
}

@MainActor private struct ConnectionRow: View {
    @Bindable var drive: DriveModel
    let reconnect: () -> Void
    let disconnect: () -> Void
    let perform: (DriveAction) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "externaldrive.badge.wifi")
                .font(.system(size: 28)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(drive.name).font(.headline)
                Text("\(drive.share) · \(drive.host)").font(.callout).foregroundStyle(.secondary)
                if !drive.status.isEmpty {
                    Text(drive.status).font(.caption).textSelection(.enabled)
                }
                if !drive.connectionStatus.isEmpty {
                    Text(drive.connectionStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if drive.busy { ProgressView().controlSize(.small) }
            Button("Open in Finder") { perform(.openFinder) }.disabled(drive.busy)
            Menu {
                Button("Reconnect…", action: reconnect)
                Button("Refresh") { perform(.refresh) }
                Button("Free Up Space") { perform(.offloadAll) }
                Divider()
                Button("Disconnect…", role: .destructive, action: disconnect)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(drive.busy)
            .help("Actions for \(drive.name)")
            .accessibilityLabel("Actions for \(drive.name)")
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

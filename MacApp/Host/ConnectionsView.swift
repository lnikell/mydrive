import SwiftUI

private struct ConnectionSheetRequest: Identifiable {
    let id = UUID()
    let settings: ConnectionSettings
    let drive: DriveModel?
}

@MainActor struct ConnectionsView: View {
    @Bindable var model: AppModel
    @Binding var addRequested: Bool
    @State private var sheet: ConnectionSheetRequest?
    @State private var removingDrive: DriveModel?
    @State private var showingLoadIssues = false

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
                        }, disconnect: { removingDrive = drive })
                    }
                }
                .listStyle(.inset)
            }
            footer
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
        }
        .onChange(of: addRequested) { _, _ in presentRequestedAdd() }
        .sheet(item: $sheet) { request in
            DriveConnectionSheet(model: model, settings: request.settings, drive: request.drive)
        }
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
            Text("Files on the NAS are kept. macOS preserves any pending local work. This removes this drive’s Finder location, downloads and connection settings.")
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
                Text(AppStorage.isDevelopmentStorage
                     ? "Development · Read-only · Credentials last 15 minutes."
                     : "Read-only preview · Keep files downloaded using Finder.")
                    .font(.caption).foregroundStyle(.secondary)
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
        guard !model.busy, sheet == nil, removingDrive == nil else { return }
        sheet = ConnectionSheetRequest(settings: model.makeDraft(), drive: nil)
    }

    private func presentRequestedAdd() {
        guard addRequested, !model.busy else { return }
        addRequested = false
        presentAdd()
    }
}

@MainActor private struct ConnectionRow: View {
    @Bindable var drive: DriveModel
    let reconnect: () -> Void
    let disconnect: () -> Void

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
            Button("Open in Finder") { Task { await drive.openFinder() } }.disabled(drive.busy)
            Menu {
                Button("Reconnect…", action: reconnect)
                Button("Refresh") { Task { await drive.refresh() } }
                Button("Free Up Space") { Task { await drive.offloadAll() } }
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

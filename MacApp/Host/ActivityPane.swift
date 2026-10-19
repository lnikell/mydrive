import AppKit
import SwiftUI

enum ActivityFilter: Hashable { case all, uploading, downloading, queued, issues }

private enum Column {
    static let mount: CGFloat = 140
    static let progress: CGFloat = 170
    static let speed: CGFloat = 84
    static let status: CGFloat = 124
    static let actions: CGFloat = 104
}

/// File transfers, pending work and mount operations use the design's existing
/// rows. A retry updates one issue per file; attempts remain in history.
@MainActor struct ActivityPane: View {
    @Bindable var model: AppModel
    let log: ActivityLog
    let actions: MountActions
    let showRetainedWork: () -> Void
    let showLoadIssues: () -> Void
    @State private var filter = ActivityFilter.all
    @State private var showingCompleted = false
    @State private var reviewing: (DriveModel, TransferEntry)?
    private var activeTransfers: [DriveTransfer] { model.transfers.filter { $0.entry.active } }
    private var transferIssues: [DriveTransfer] {
        var latest: [String: DriveTransfer] = [:]
        for item in model.transfers.sorted(by: { $0.entry.started < $1.entry.started })
            where !item.entry.resolved && (item.entry.state == .failed || item.entry.state == .interrupted || item.entry.conflict) {
            latest[item.drive.id + ":" + item.entry.itemID + (item.entry.conflict ? ":conflict" : ":failure")] = item
        }
        return latest.values.sorted { $0.entry.started > $1.entry.started }
    }
    private var finishedTransfers: [DriveTransfer] {
        let issues = Set(transferIssues.map(\.id))
        return model.transfers.filter { $0.entry.state == .completed && !issues.contains($0.id) && Calendar.current.isDateInToday($0.entry.finished ?? $0.entry.started) }
            .sorted { ($0.entry.finished ?? $0.entry.started) > ($1.entry.finished ?? $1.entry.started) }
    }
    private var filteredTransfers: [DriveTransfer] {
        activeTransfers.filter { item in
            let entry = item.entry
            return switch filter {
            case .all: true
            case .uploading: entry.direction == .uploading && entry.state != .queued
            case .downloading: entry.direction == .downloading && entry.state != .queued
            case .queued: entry.state == .queued
            case .issues: false
            }
        }
    }

    private var working: [DriveModel] { model.drives.filter(\.busy) }
    private var attention: [DriveModel] { model.drives.filter { !$0.busy && $0.health.needsAttention } }
    private var hasAppIssues: Bool { !model.loadIssues.isEmpty || !model.retainedWork.isEmpty }
    private var completed: [ActivityLog.Entry] {
        log.completed.filter { Calendar.current.isDateInToday($0.date) }
    }
    private var issueCount: Int { attention.count + transferIssues.count + (hasAppIssues ? 1 : 0) }
    private var inFlight: Int { activeTransfers.count + working.count + (model.busy ? 1 : 0) }

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: "Activity", detail: inFlight > 0 ? "\(inFlight) in progress" : nil) {
                SegmentedPicker(selection: $filter, segments: [
                    .init(value: .all, title: "All"),
                    .init(value: .uploading, title: "Uploading"),
                    .init(value: .downloading, title: "Downloading"),
                    .init(value: .queued, title: "Queued"),
                    .init(value: .issues, title: "Issues")
                ])
                Button { Task { await model.setAllPaused(!model.allPaused) } } label: {
                    HStack(spacing: 6) { Icon(model.allPaused ? .sync : .pause, size: 13); Text(model.allPaused ? "Resume All" : "Pause All") }
                }
                .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                .disabled(model.busy || model.drives.isEmpty)
            }
            if showsEmptyState {
                UpToDateView(model: model, hasCompleted: !completed.isEmpty || !finishedTransfers.isEmpty) { showingCompleted = true }
            } else {
                if inFlight > 0 && filter == .all { summary }
                header
                ScrollView {
                    LazyVStack(spacing: 0) { groups }
                }
            }
        }
        .onChange(of: filter) { _, value in if value == .issues { showingCompleted = true } }
        .alert("Sync Conflict", isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
            if let (drive, entry) = reviewing {
                Button("Show Both Copies in Finder") {
                    Task {
                        do { try await drive.perform(.showFinder, itemID: entry.itemID) }
                        catch { model.report(error.localizedDescription) }
                    }
                }
            }
            Button("Done", role: .cancel) {
                if let (drive, entry) = reviewing {
                    Task {
                        do { try await DomainManagement(settings: drive.settings).resolveActivity(entry.id); await drive.readSnapshot() }
                        catch { model.report(error.localizedDescription) }
                    }
                }
                reviewing = nil
            }
        } message: {
            Text("The server version and your edit were both kept. Review the conflict copy in Finder, then keep or merge the versions you need. " + (reviewing?.1.name ?? ""))
        }
    }

    private var showsEmptyState: Bool {
        switch filter {
        case .issues: false
        default: inFlight == 0 && issueCount == 0 && !showingCompleted
        }
    }

    @ViewBuilder private var groups: some View {
        if filter == .all && inFlight > 0 {
            GroupHeader(title: "In progress", count: inFlight)
        } else if !filteredTransfers.isEmpty {
            GroupHeader(title: filter == .queued ? "Queued" : "In progress", count: filteredTransfers.count)
        }
        ForEach(filteredTransfers) { item in
            transferRow(item.drive, item.entry).id("active-" + item.id)
        }
        if filter == .all && inFlight > 0 {
            if model.busy {
                ActivityRow(icon: .sync, title: model.status.firstLine.isEmpty ? "Working…" : model.status.firstLine,
                            subtitle: "MyDrive", drive: nil, highlighted: true) {
                    Text("—").foregroundStyle(Palette.tertiary)
                } status: {
                    Label { Text("Working") } icon: { ProgressView().controlSize(.mini) }
                } trailing: { EmptyView() }
            }
            ForEach(working) { drive in
                ActivityRow(icon: .sync, title: drive.status.isEmpty ? "Working…" : drive.status.firstLine,
                            subtitle: drive.address, drive: drive, highlighted: true) {
                    Text("—").foregroundStyle(Palette.tertiary)
                } status: {
                    Label { Text("Working") } icon: { ProgressView().controlSize(.mini) }
                } trailing: { EmptyView() }
            }
        }
        if issueCount > 0 && (filter == .all || filter == .issues) {
            GroupHeader(title: "Needs attention", count: issueCount)
            ForEach(transferIssues) { item in
                transferRow(item.drive, item.entry).id("issue-" + item.id)
            }
            ForEach(attention) { drive in
                let health = drive.health
                ActivityRow(icon: .warning, title: health.title, subtitle: drive.connectionStatus.isEmpty
                                ? drive.healthDetail.firstLine : drive.connectionStatus.firstLine,
                            drive: drive) {
                    Text(drive.address).foregroundStyle(Palette.tertiary)
                } status: {
                    Label { Text(health.shortTitle) } icon: { Icon(.warning, size: 13) }
                        .foregroundStyle(health.color)
                } trailing: {
                    if health.needsReconnect {
                        Button("Reconnect…") { actions.reconnect(drive) }
                            .buttonStyle(CardButtonStyle(horizontalPadding: 9))
                    } else {
                        Button("Retry") { actions.perform(.refresh, drive) }
                            .buttonStyle(CardButtonStyle(horizontalPadding: 9))
                    }
                }
                .help(drive.healthDetail)
            }
            if !model.loadIssues.isEmpty {
                ActivityRow(icon: .warning, title: "Saved mount issues",
                            subtitle: model.loadIssues.first?.message.firstLine ?? "", drive: nil) {
                    Text("\(model.loadIssues.count) \(model.loadIssues.count == 1 ? "issue" : "issues")")
                        .foregroundStyle(Palette.tertiary)
                } status: {
                    Label { Text("Review") } icon: { Icon(.warning, size: 13) }.foregroundStyle(Palette.orange)
                } trailing: {
                    Button("Details…", action: showLoadIssues).buttonStyle(CardButtonStyle(horizontalPadding: 9))
                }
            }
            if !model.retainedWork.isEmpty {
                // Edits that had not uploaded when a mount was disconnected; MyDrive saved them locally.
                ActivityRow(icon: .folder, title: "Unsynced changes saved on this Mac",
                            subtitle: model.retainedWork.first?.path ?? "", drive: nil) {
                    Text("\(model.retainedWork.count) \(model.retainedWork.count == 1 ? "folder" : "folders")")
                        .foregroundStyle(Palette.tertiary)
                } status: {
                    Label { Text("Review") } icon: { Icon(.info, size: 13) }.foregroundStyle(Palette.secondary)
                } trailing: {
                    if model.retainedWork.count == 1, let location = model.retainedWork.first {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                            .buttonStyle(CardButtonStyle(horizontalPadding: 9))
                            .help("Show in Finder")
                    } else {
                        Button("Show…", action: showRetainedWork).buttonStyle(CardButtonStyle(horizontalPadding: 9))
                    }
                }
                .help("Changes that hadn't uploaded when a mount was disconnected. Copy anything you still need back to the server.")
            }
        }
        if filter == .all && (showingCompleted || inFlight > 0 || issueCount > 0) {
            GroupHeader(title: "Completed today", count: completed.count + finishedTransfers.count) {
                if !completed.isEmpty || !finishedTransfers.isEmpty {
                    LinkButton(title: "Clear") {
                        log.clearCompleted(); showingCompleted = false
                        Task {
                            for drive in model.drives where drive.isRegistered && !drive.isPaused {
                                do { try await DomainManagement(settings: drive.settings).clearActivity() }
                                catch { model.report(error.localizedDescription) }
                            }
                            await model.refreshSnapshots()
                        }
                    }
                }
            }
            ForEach(finishedTransfers) { item in
                transferRow(item.drive, item.entry).id("history-" + item.id)
            }
            if completed.isEmpty && finishedTransfers.isEmpty {
                Text("Nothing has finished yet in this session.")
                    .font(Typography.callout).foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            ForEach(completed) { entry in
                let drive = entry.driveID.flatMap { id in model.drives.first { $0.id == id } }
                ActivityRow(icon: .check, title: entry.message.firstLine,
                            subtitle: entry.driveName ?? "MyDrive", drive: drive, mountName: entry.driveName) {
                    Text("Done").foregroundStyle(Palette.tertiary)
                } status: {
                    Label { Text("Finished \(RelativeTime.clock(entry.date))") } icon: { Icon(.check, size: 13) }
                        .foregroundStyle(Palette.secondary)
                } trailing: { EmptyView() }
                .help(entry.message)
            }
        }
    }

    private func transferRow(_ drive: DriveModel, _ entry: TransferEntry) -> some View {
        ActivityRow(icon: entry.direction == .operation ? .sync : entry.direction == .uploading ? .arrowUp : .arrowDown, title: entry.name,
                    subtitle: transferDetail(entry), drive: drive,
                    highlighted: entry.active, speed: TransferFormat.speed(entry.bytesPerSecond)) {
            HStack(spacing: 8) {
                ProgressBar(value: entry.fraction).frame(width: 100)
                Text(entry.fraction.map { "\(Int($0 * 100)) %" } ?? "—").foregroundStyle(Palette.secondary)
            }
        } status: {
            Text(drive.isPaused && entry.active ? "Paused" : entry.conflict ? "Conflict copy" : entry.message)
                .foregroundStyle(entry.state == .failed ? Palette.red : Palette.secondary)
        } trailing: {
            if entry.conflict {
                Button("Resolve…") { reviewing = (drive, entry) }.buttonStyle(CardButtonStyle(horizontalPadding: 9))
            } else if entry.state == .failed || entry.state == .interrupted {
                Button("Retry") {
                    Task {
                        do { try await DomainManagement(settings: drive.settings).retryTransfer(download: entry.direction == .downloading, itemID: entry.itemID) }
                        catch { model.report(error.localizedDescription) }
                    }
                }.buttonStyle(CardButtonStyle(horizontalPadding: 9)).disabled(drive.isPaused)
            }
        }
    }

    private func transferDetail(_ entry: TransferEntry) -> String {
        let folder = entry.path?.split(separator: "/").dropLast().joined(separator: "/") ?? ""
        let size = entry.direction == .operation ? "Mount operation" : ByteCountFormatter.string(fromByteCount: entry.total, countStyle: .file)
        return folder.isEmpty ? size : folder + " · " + size
    }

    private var summary: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(inFlight == 1 ? "1 operation in progress" : "\(inFlight) operations in progress")
                    .font(Typography.bodyMedium).foregroundStyle(Palette.primary)
                Text(Array(Set(working.map(\.name) + activeTransfers.map { $0.drive.name })).sorted().joined(separator: ", ").ifEmpty("MyDrive"))
                    .font(Typography.callout).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            if let fraction = TransferFormat.fraction(model.transfers.map(\.entry)) {
                ProgressBar(value: fraction, height: 6).frame(width: 220)
            }
            Spacer(minLength: 0)
            Label { Text(TransferFormat.speed(activeTransfers.filter { $0.entry.direction == .uploading }.reduce(0) { $0 + $1.entry.bytesPerSecond })) } icon: { Icon(.arrowUp, size: 13) }
            Label { Text(TransferFormat.speed(activeTransfers.filter { $0.entry.direction == .downloading }.reduce(0) { $0 + $1.entry.bytesPerSecond })) } icon: { Icon(.arrowDown, size: 13) }
            Label { Text(issueCount == 1 ? "1 issue" : "\(issueCount) issues") } icon: { Icon(.warning, size: 13) }
        }
        .font(Typography.callout)
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Palette.subtle)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var header: some View {
        HStack(spacing: TableLayout.columnGap) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Mount").frame(width: Column.mount, alignment: .leading)
            Text("Progress").frame(width: Column.progress, alignment: .leading)
            Text("Speed").frame(width: Column.speed, alignment: .leading)
            Text("Status").frame(width: Column.status, alignment: .leading)
            Color.clear.frame(width: Column.actions, height: 1)
        }
        .font(Typography.subheadline.weight(.medium))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 20)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct ActivityRow<Progress: View, Status: View, Trailing: View>: View {
    let icon: DesignIcon
    let title: String
    let subtitle: String
    let drive: DriveModel?
    var mountName: String?
    var highlighted = false
    var speed = "—"
    @ViewBuilder let progress: () -> Progress
    @ViewBuilder let status: () -> Status
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: TableLayout.columnGap) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.control)
                    .frame(width: 28, height: 28)
                    .overlay(Icon(icon, size: 14).foregroundStyle(Palette.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Typography.bodyMedium).foregroundStyle(Palette.primary)
                    Text(subtitle).font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                if let drive {
                    DriveBadge(kind: drive.kind, size: 16, style: .solid)
                    Text(drive.name)
                } else if let mountName {
                    DriveBadge(kind: .smb, size: 16, style: .solid)
                    Text(mountName)
                } else {
                    Text("—")
                }
            }
            .font(Typography.callout).foregroundStyle(Palette.secondary).lineLimit(1)
            .frame(width: Column.mount, alignment: .leading)
            progress()
                .font(Typography.callout).lineLimit(1).truncationMode(.middle)
                .frame(width: Column.progress, alignment: .leading)
            Text(speed).font(Typography.callout).foregroundStyle(Palette.secondary)
                .frame(width: Column.speed, alignment: .leading)
            status()
                .labelStyle(StatusLabelStyle())
                .font(Typography.callout).foregroundStyle(Palette.primary).lineLimit(1)
                .frame(width: Column.status, alignment: .leading)
            // A ZStack keeps the column's width even when the row has no action.
            ZStack(alignment: .trailing) { Color.clear; trailing() }.frame(width: Column.actions)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(highlighted ? Palette.accentSoft : .clear)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}

/// "Empty — everything synced", backed by the coordinator's durable totals.
@MainActor private struct UpToDateView: View {
    @Bindable var model: AppModel
    let hasCompleted: Bool
    let showCompleted: () -> Void

    private var lastChecked: Date? { model.drives.compactMap(\.lastChecked).max() }

    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(Palette.greenSoft).frame(width: 72, height: 72)
                .overlay(Icon(.check, size: 34).foregroundStyle(Palette.green))
            Text(model.allPaused ? "Syncing is paused" : model.drives.contains(where: { $0.isRegistered && $0.snapshot == nil })
                ? "Checking activity…" : "Everything is up to date")
                .font(Typography.title2).foregroundStyle(Palette.primary).padding(.top, 16)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(subtitle(now: context.date)).font(Typography.body).foregroundStyle(Palette.secondary)
            }
            .padding(.top, 6)
            HStack(spacing: 0) {
                stat("\(model.drives.reduce(Int64(0)) { NonnegativeTotals.add($0, $1.snapshot?.today.files ?? 0) })", "files synced today")
                stat(total(.uploading), "uploaded").overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 1) }
                stat(total(.downloading), "downloaded").overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 1) }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.subtle))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1))
            .padding(.top, 24)
            Button("Show Completed Transfers", action: showCompleted)
                .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                .disabled(!hasCompleted)
                .padding(.top, 20)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var today: [TransferEntry] {
        model.transfers.map(\.entry).filter { $0.state == .completed && $0.direction != .operation &&
            Calendar.current.isDateInToday($0.finished ?? $0.started) }
    }

    private func total(_ direction: TransferEntry.Direction) -> String {
        let bytes = model.drives.reduce(Int64(0)) { value, drive in
            NonnegativeTotals.add(value, direction == .uploading ? drive.snapshot?.today.uploaded ?? 0 : drive.snapshot?.today.downloaded ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func subtitle(now: Date) -> String {
        let count = model.drives.count
        var text = count == 1 ? "1 mount watched" : "\(count) mounts watched"
        if let lastChecked { text += " · last checked \(RelativeTime.short(lastChecked, now: now).lowercased())" }
        return text
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(Typography.title3).foregroundStyle(Palette.primary)
            Text(label).font(Typography.subheadline).foregroundStyle(Palette.tertiary)
        }
        .padding(.vertical, 12)
        .frame(width: 150)
    }
}

extension String {
    var firstLine: String { split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

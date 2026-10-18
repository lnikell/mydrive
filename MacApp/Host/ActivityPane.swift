import AppKit
import SwiftUI

enum ActivityFilter: Hashable { case all, uploading, downloading, queued, issues }

private let transferHelp = "Per-file transfer tracking isn't available yet."

private enum Column {
    static let mount: CGFloat = 150
    static let progress: CGFloat = 190
    static let speed: CGFloat = 90
    static let status: CGFloat = 130
    static let actions: CGFloat = 96
}

/// "Activity — full sync process". The provider does not report per-file
/// transfers yet, so rows are mount operations, mounts that need attention and
/// this session's completed operations.
@MainActor struct ActivityPane: View {
    @Bindable var model: AppModel
    let log: ActivityLog
    let actions: MountActions
    let showRetainedWork: () -> Void
    let showLoadIssues: () -> Void
    @State private var filter = ActivityFilter.all
    @State private var showingCompleted = false

    private var working: [DriveModel] { model.drives.filter(\.busy) }
    private var attention: [DriveModel] { model.drives.filter { !$0.busy && $0.health.needsAttention } }
    private var hasAppIssues: Bool { !model.loadIssues.isEmpty || !model.retainedWork.isEmpty }
    private var completed: [ActivityLog.Entry] {
        log.completed.filter { Calendar.current.isDateInToday($0.date) }
    }
    private var issueCount: Int { attention.count + (hasAppIssues ? 1 : 0) }
    private var inFlight: Int { working.count + (model.busy ? 1 : 0) }

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: "Activity", detail: inFlight > 0 ? "\(inFlight) in progress" : nil) {
                SegmentedPicker(selection: $filter, segments: [
                    .init(value: .all, title: "All"),
                    .init(value: .uploading, title: "Uploading", enabled: false, help: transferHelp),
                    .init(value: .downloading, title: "Downloading", enabled: false, help: transferHelp),
                    .init(value: .queued, title: "Queued", enabled: false, help: transferHelp),
                    .init(value: .issues, title: "Issues")
                ])
                Button {} label: {
                    HStack(spacing: 6) { Icon(.pause, size: 13); Text("Pause All") }
                }
                .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                .disabled(true)
                .help("Pausing sync isn't available yet.")
            }
            if showsEmptyState {
                UpToDateView(model: model, hasCompleted: !completed.isEmpty) { showingCompleted = true }
            } else {
                if inFlight > 0 && filter == .all { summary }
                header
                ScrollView {
                    LazyVStack(spacing: 0) { groups }
                }
            }
        }
        .onChange(of: filter) { _, value in if value == .issues { showingCompleted = true } }
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
            if model.busy {
                ActivityRow(icon: .sync, title: model.status.firstLine.isEmpty ? "Working…" : model.status.firstLine,
                            subtitle: "MyDrive", drive: nil, highlighted: true) {
                    ProgressBar(value: nil).frame(width: 130)
                } status: {
                    Label { Text("Working") } icon: { ProgressView().controlSize(.mini) }
                } trailing: { EmptyView() }
            }
            ForEach(working) { drive in
                ActivityRow(icon: .sync, title: drive.status.isEmpty ? "Working…" : drive.status.firstLine,
                            subtitle: drive.address, drive: drive, highlighted: true) {
                    ProgressBar(value: nil).frame(width: 130)
                } status: {
                    Label { Text("Working") } icon: { ProgressView().controlSize(.mini) }
                } trailing: { EmptyView() }
            }
        }
        if issueCount > 0 {
            GroupHeader(title: "Needs attention", count: issueCount)
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
                ActivityRow(icon: .folder, title: "Retained local work",
                            subtitle: model.retainedWork.first?.path ?? "", drive: nil) {
                    Text("\(model.retainedWork.count) \(model.retainedWork.count == 1 ? "location" : "locations")")
                        .foregroundStyle(Palette.tertiary)
                } status: {
                    Label { Text("Kept") } icon: { Icon(.info, size: 13) }.foregroundStyle(Palette.secondary)
                } trailing: {
                    Button("Show…", action: showRetainedWork).buttonStyle(CardButtonStyle(horizontalPadding: 9))
                }
            }
        }
        if filter == .all && (showingCompleted || inFlight > 0 || issueCount > 0) {
            GroupHeader(title: "Completed today", count: completed.count) {
                if !completed.isEmpty { LinkButton(title: "Clear") { log.clearCompleted(); showingCompleted = false } }
            }
            if completed.isEmpty {
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

    private var summary: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(inFlight == 1 ? "1 operation in progress" : "\(inFlight) operations in progress")
                    .font(Typography.bodyMedium).foregroundStyle(Palette.primary)
                Text(working.map(\.name).joined(separator: ", ").ifEmpty("MyDrive"))
                    .font(Typography.callout).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            ProgressBar(value: nil, height: 6).frame(width: 220)
            Spacer(minLength: 0)
            Label { Text("—") } icon: { Icon(.arrowUp, size: 13) }
                .help("Transfer speed isn't reported yet.")
            Label { Text("—") } icon: { Icon(.arrowDown, size: 13) }
                .help("Transfer speed isn't reported yet.")
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
        HStack(spacing: 0) {
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
    @ViewBuilder let progress: () -> Progress
    @ViewBuilder let status: () -> Status
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
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
            Text("—").font(Typography.callout).foregroundStyle(Palette.secondary)
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

/// "Empty — everything synced". Daily transfer totals are not reported yet.
@MainActor private struct UpToDateView: View {
    @Bindable var model: AppModel
    let hasCompleted: Bool
    let showCompleted: () -> Void

    private var lastChecked: Date? { model.drives.compactMap(\.lastChecked).max() }

    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(Palette.greenSoft).frame(width: 72, height: 72)
                .overlay(Icon(.check, size: 34).foregroundStyle(Palette.green))
            Text("Everything is up to date").font(Typography.title2).foregroundStyle(Palette.primary).padding(.top, 16)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(subtitle(now: context.date)).font(Typography.body).foregroundStyle(Palette.secondary)
            }
            .padding(.top, 6)
            HStack(spacing: 0) {
                stat("—", "files synced today")
                stat("—", "uploaded").overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 1) }
                stat("—", "downloaded").overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 1) }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.subtle))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1))
            .help("Transfer totals aren't reported yet.")
            .padding(.top, 24)
            Button("Show Completed Activity", action: showCompleted)
                .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                .disabled(!hasCompleted)
                .padding(.top, 20)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

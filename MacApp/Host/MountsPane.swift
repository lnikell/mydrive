import AppKit
import SwiftUI

/// Actions the window owns: sheets, confirmations and navigation.
struct MountActions {
    let addSMB: () -> Void
    let connectToURL: () -> Void
    let reconnect: (DriveModel) -> Void
    let disconnect: (DriveModel) -> Void
    let perform: (DriveAction, DriveModel) -> Void
    let refreshAll: () -> Void
}

private enum Column {
    static let kind: CGFloat = 96
    static let status: CGFloat = 160
    static let cached: CGFloat = 84
    static let lastSync: CGFloat = 110
    static let actions: CGFloat = 56
}

@MainActor struct MountsPane: View {
    @Bindable var model: AppModel
    let kind: MountKind?
    let actions: MountActions
    @Binding var query: String
    @State private var ascending = true
    @State private var selection: String?

    private var scoped: [DriveModel] { model.drives.filter { kind == nil || $0.kind == kind } }

    private var visible: [DriveModel] {
        scoped.filter { $0.matches(query) }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private var countDetail: String? {
        guard !scoped.isEmpty else { return nil }
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return filtering ? "\(visible.count) of \(scoped.count)" : "\(scoped.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: kind?.title ?? "All Mounts", detail: countDetail) {
                FilterField(prompt: "Filter mounts", text: $query)
                    .disabled(model.drives.isEmpty)
                    .opacity(model.drives.isEmpty ? 0.45 : 1)
                Button(action: actions.refreshAll) { Icon(.sync, size: 15) }
                    .buttonStyle(IconButtonStyle())
                    .disabled(model.busy || !model.drives.contains { $0.isRegistered && !$0.busy })
                    .help("Check all mounts for changes")
                    .accessibilityLabel("Refresh all mounts")
                AddMenuButton(addSMB: actions.addSMB, connectToURL: actions.connectToURL)
                    .disabled(model.busy)
            }
            if model.drives.isEmpty {
                if model.busy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FirstLaunchView(actions: actions)
                }
            } else {
                header
                if visible.isEmpty {
                    NoResultsView(query: query) { query = "" }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { drive in
                                MountRow(drive: drive, isSelected: selection == drive.id, actions: actions,
                                         appBusy: model.busy) { selection = drive.id }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .onChange(of: model.drives.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button { ascending.toggle() } label: {
                HStack(spacing: 4) {
                    Text("Name")
                    Icon(.chevronDown, size: 11).rotationEffect(.degrees(ascending ? 0 : 180))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ascending ? "Sorted A to Z" : "Sorted Z to A")
            .accessibilityLabel("Sort by name")
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Protocol").frame(width: Column.kind, alignment: .leading)
            Text("Status").frame(width: Column.status, alignment: .leading)
            Text("Cached").frame(width: Column.cached, alignment: .leading)
            Text("Last sync").frame(width: Column.lastSync, alignment: .leading)
            Color.clear.frame(width: Column.actions, height: 1)
        }
        .font(Typography.subheadline.weight(.medium))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 20)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

@MainActor private struct MountRow: View {
    @Bindable var drive: DriveModel
    let isSelected: Bool
    let actions: MountActions
    let appBusy: Bool
    let select: () -> Void
    @State private var hovering = false

    private var disabled: Bool { drive.busy || appBusy }

    var body: some View {
        let health = drive.health
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                DriveBadge(kind: drive.kind, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name).font(Typography.bodyMedium).foregroundStyle(Palette.primary)
                    Text(drive.address).font(Typography.mono).foregroundStyle(Palette.secondary)
                        .textSelection(.enabled)
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Chip(title: drive.kind.chipTitle).frame(width: Column.kind, alignment: .leading)
            statusCell(health).frame(width: Column.status, alignment: .leading)
            // Per-mount cache size is not reported by the provider yet.
            Text("—").font(Typography.callout).foregroundStyle(Palette.tertiary)
                .frame(width: Column.cached, alignment: .leading)
                .help("Cache size isn't measured yet.")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(drive.busy ? "Syncing…" : RelativeTime.short(drive.lastChecked, now: context.date))
                    .font(Typography.callout).foregroundStyle(Palette.secondary)
            }
            .frame(width: Column.lastSync, alignment: .leading)
            .help(drive.connectionStatus)
            HStack(spacing: 12) {
                if health.needsReconnect {
                    Button { actions.reconnect(drive) } label: { Icon(.sync, size: 15) }
                        .help("Reconnect…")
                        .accessibilityLabel("Reconnect \(drive.name)")
                } else {
                    Button { actions.disconnect(drive) } label: { Icon(.eject, size: 15) }
                        .help("Disconnect…")
                        .accessibilityLabel("Disconnect \(drive.name)")
                }
                MenuButton(entries: { menuEntries }) { _ in Icon(.ellipsis, size: 15) }
                    .help("Actions for \(drive.name)")
                    .accessibilityLabel("Actions for \(drive.name)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondary)
            .disabled(disabled)
            .frame(width: Column.actions, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(isSelected ? Palette.accentSoft : (hovering ? Palette.hover : .clear))
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !disabled { actions.perform(.openFinder, drive) } }
        .simultaneousGesture(TapGesture().onEnded(select))
        .contextMenu {
            Group {
                Button("Open in Finder") { actions.perform(.openFinder, drive) }
                Button("Refresh") { actions.perform(.refresh, drive) }
                Button("Free Up Space") { actions.perform(.offloadAll, drive) }
                Divider()
                Button("Reconnect…") { actions.reconnect(drive) }
                Button("Disconnect…", role: .destructive) { actions.disconnect(drive) }
            }
            .disabled(disabled)
        }
        .disabled(appBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(drive.name), \(drive.address), \(health.title)")
    }

    @ViewBuilder private func statusCell(_ health: MountHealth) -> some View {
        HStack(spacing: 8) {
            if case let .working(status) = health {
                ProgressView().controlSize(.mini)
                Text(status).foregroundStyle(Palette.primary)
            } else {
                StatusDot(color: health.color)
                Text(health.title).foregroundStyle(health.needsAttention ? health.color : Palette.primary)
            }
        }
        .font(Typography.callout)
        .lineLimit(1)
        .help(drive.healthDetail)
    }

    private var menuEntries: [MenuEntry] {
        let drive = self.drive, actions = self.actions
        return [
            .item("Open in Finder", action: { actions.perform(.openFinder, drive) }),
            .item("Refresh", action: { actions.perform(.refresh, drive) }),
            .item("Free Up Space", action: { actions.perform(.offloadAll, drive) }),
            .separator,
            .item("Reconnect…", action: { actions.reconnect(drive) }),
            .item("Disconnect…", action: { actions.disconnect(drive) })
        ]
    }
}

/// "Empty — first launch": one call to action and the protocols that work today.
@MainActor private struct FirstLaunchView: View {
    let actions: MountActions

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DriveBadge(kind: .sftp, size: 60, style: .solid).rotationEffect(.degrees(-12)).offset(x: -42, y: 10)
                DriveBadge(kind: .s3, size: 60, style: .solid).rotationEffect(.degrees(12)).offset(x: 44, y: 10)
                DriveBadge(kind: .smb, size: 60, style: .solid)
            }
            .frame(width: 190, height: 100)
            Text("No mounts yet").font(Typography.title2).foregroundStyle(Palette.primary).padding(.top, 18)
            Text("Connect a NAS, server or bucket and it shows up in Finder like any other folder. Files stay online until you open them.")
                .font(Typography.body).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center).lineSpacing(3)
                .frame(width: 400).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack(spacing: 8) {
                Button(action: actions.addSMB) {
                    HStack(spacing: 6) { Icon(.plus, size: 15); Text("Add Mount…") }
                }
                .buttonStyle(AccentButtonStyle(height: 32, radius: 9, horizontalPadding: 14))
                Button("Connect to URL…", action: actions.connectToURL)
                    .buttonStyle(CardButtonStyle(height: 32, radius: 9, horizontalPadding: 12))
            }
            .padding(.top, 20)
            HStack(spacing: 6) {
                Text("Works with").font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                ForEach(MountKind.addMenuOrder.filter(\.isAvailable)) { kind in Chip(title: kind.title) }
            }
            .padding(.top, 14)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Empty — no search results": repeats the query and offers one way out.
private struct NoResultsView: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        EmptyState(title: "No mounts match “\(query.trimmingCharacters(in: .whitespaces))”",
                   message: "Search by name, host, protocol or path, for example “nas.local” or “SMB”.") {
            IconTile(icon: .search)
        } actions: {
            Button("Clear Filter", action: clear).buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
        }
    }
}

/// Library sections whose data the provider does not expose yet.
struct PlaceholderPane: View {
    let title: String
    let icon: DesignIcon
    let heading: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: title) { EmptyView() }
            EmptyState(title: heading, message: message) { IconTile(icon: icon) } actions: { EmptyView() }
        }
    }
}

import SwiftUI

enum SidebarItem: Hashable {
    case allMounts, onlineOnly, keptOffline, activity, discovered
    case kind(MountKind)
}

@MainActor struct Sidebar: View {
    @Binding var selection: SidebarItem
    let drives: [DriveModel]
    let activityBadge: Int
    let cache: CacheUsage
    let cacheLimitGB: Double
    let openCacheSettings: () -> Void
    let openSettings: () -> Void

    /// Protocol rows appear only for protocols that have at least one mount.
    private var kinds: [MountKind] {
        MountKind.protocols.filter { kind in drives.contains { $0.kind == kind } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Room for the traffic lights in the 52 pt title bar band.
            Color.clear.frame(height: 52)
            SectionTitle(title: "Library", top: 6)
            NavRow(title: "All Mounts", isSelected: selection == .allMounts,
                   count: drives.isEmpty ? nil : drives.count) { select(.allMounts) } icon: { Icon(.server) }
            NavRow(title: "Online-only", isSelected: selection == .onlineOnly,
                   count: cache.measuredAt == nil ? nil : Int(cache.onlineOnlyCount)) { select(.onlineOnly) } icon: { Icon(.cloud) }
            NavRow(title: "Kept Offline", isSelected: selection == .keptOffline,
                   count: cache.measuredAt == nil ? nil : Int(cache.offlineSelectionCount)) { select(.keptOffline) } icon: { Icon(.pin) }
            NavRow(title: "Activity", isSelected: selection == .activity,
                   badge: activityBadge > 0 ? activityBadge : nil) { select(.activity) } icon: { Icon(.activity) }
            NavRow(title: "Discovered", isSelected: selection == .discovered,
                   count: DiscoveryService.shared.peers.isEmpty ? nil : DiscoveryService.shared.peers.count) { select(.discovered) } icon: { Icon(.tailnet) }
            if !kinds.isEmpty {
                SectionTitle(title: "Protocols", top: 18)
                ForEach(kinds) { kind in
                    NavRow(title: kind.title, isSelected: selection == .kind(kind),
                           count: drives.filter { $0.kind == kind }.count, tintsIcon: false) {
                        select(.kind(kind))
                    } icon: {
                        DriveBadge(kind: kind, size: 18)
                    }
                }
            }
            Spacer(minLength: 12)
            LocalCacheCard(cache: cache, limitGB: cacheLimitGB, action: openCacheSettings)
            Color.clear.frame(height: 8)
            NavRow(title: "Settings", isSelected: false, action: openSettings) { Icon(.settings) }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.separator).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private func select(_ item: SidebarItem) { selection = item }
}

private struct SectionTitle: View {
    let title: String
    let top: CGFloat
    var body: some View {
        Text(title)
            .font(Typography.section)
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, top)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NavRow<Leading: View>: View {
    let title: String
    let isSelected: Bool
    var count: Int?
    var badge: Int?
    var tintsIcon = true
    let action: () -> Void
    @ViewBuilder let icon: () -> Leading
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon()
                    .foregroundStyle(isSelected && tintsIcon ? Palette.accent : Palette.secondary)
                Text(title).font(Typography.body).foregroundStyle(Palette.primary).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)")
                        .font(Typography.section)
                        .tracking(0.1)
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.accent))
                } else if let count {
                    Text("\(count)").font(Typography.callout).foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Palette.selected : (hovering ? Palette.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(badge.map { "\($0) items" } ?? count.map { "\($0)" } ?? "")
    }
}

/// "Sidebar/Local Cache": opens Settings › Sync & Cache. Cache usage is not
/// reported by the provider yet, so the card shows no figure.
private struct LocalCacheCard: View {
    let cache: CacheUsage
    let limitGB: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Local cache").font(Typography.callout).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(cache.measuredAt == nil ? "—" : ByteCountFormatter.string(fromByteCount: cache.total, countStyle: .file))
                        .font(Typography.calloutMedium).foregroundStyle(Palette.primary)
                }
                ProgressBar(value: cache.measuredAt == nil ? nil : Double(cache.total) / max(1, limitGB * 1e9))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Palette.selected : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Local downloaded files. Opens Sync & Cache settings.")
        .accessibilityLabel("Local cache. Open Sync and Cache settings")
    }
}

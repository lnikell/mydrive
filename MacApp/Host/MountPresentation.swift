import Foundation
import Observation
import SwiftUI

/// What the status column and Activity screen show for one mount.
enum MountHealth: Equatable {
    case working(String)
    case mounted
    case retrying(String)
    case paused(String)
    case unregistered
    case syncPaused

    var title: String {
        switch self {
        case let .working(status): status
        case .mounted: "Mounted"
        case .retrying: "Retrying"
        case .paused: "Can't connect"
        case .unregistered: "Needs reconnect"
        case .syncPaused: "Paused"
        }
    }

    /// One word for the Activity status column.
    var shortTitle: String {
        switch self {
        case .working: "Working"
        case .mounted: "Mounted"
        case .retrying: "Retrying"
        case .paused: "Paused"
        case .unregistered: "Not set up"
        case .syncPaused: "Paused"
        }
    }

    var color: Color {
        switch self {
        case .working, .mounted: Palette.green
        case .retrying: Palette.orange
        case .paused, .unregistered: Palette.red
        case .syncPaused: Palette.secondary
        }
    }

    var needsAttention: Bool {
        switch self {
        case .retrying, .paused, .unregistered: true
        case .working, .mounted, .syncPaused: false
        }
    }

    /// Reconnecting with the password is the fix for paused and unregistered mounts.
    var needsReconnect: Bool {
        switch self {
        case .paused, .unregistered: true
        case .working, .mounted, .retrying, .syncPaused: false
        }
    }
}

extension ConnectionSettings {
    /// The smb:// address, without the default port.
    var address: String {
        let server = host.hasSuffix(":445") ? String(host.dropLast(4)) : host
        return "smb://\(server)/\(share)"
    }
}

extension DriveModel {
    /// Every saved connection is SMB today; other protocols are not implemented yet.
    var kind: MountKind { .smb }

    var address: String { settings.address }

    var health: MountHealth {
        if busy { return .working(status.isEmpty ? "Working…" : status) }
        if isPaused { return .syncPaused }
        if !isRegistered { return .unregistered }
        if snapshot?.transfers.contains(where: \.active) == true { return .working("Syncing…") }
        switch monitorState {
        case let .retrying(_, message): return .retrying(message)
        case let .paused(message): return .paused(message)
        default: return .mounted
        }
    }

    /// The fullest explanation of the current state, for tooltips and Activity.
    var healthDetail: String {
        [status, connectionStatus].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [name, host, share, username, address, kind.title]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

enum RelativeTime {
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

/// A session-only record of what MyDrive did, built from the status messages the
/// models already publish. Persistent history and per-file transfers are not
/// available from the provider yet.
@MainActor @Observable final class ActivityLog {
    struct Entry: Identifiable, Equatable, Codable {
        var id = UUID()
        let driveID: String?
        let driveName: String?
        var message: String
        var date: Date
        var inProgress: Bool
    }

    struct Snapshot: Equatable {
        let id: String
        let name: String
        let status: String
        let busy: Bool
    }

    private(set) var entries: [Entry] = []
    private var known: [String: Snapshot] = [:]
    private var appStatus = ""
    private let historyURL = try? AppStorage.rootURL().appendingPathComponent("activity-history.json")

    init() {
        if let historyURL, let bytes = try? BoundedFile.read(historyURL, maximumBytes: 1_048_576),
           let saved = try? JSONDecoder().decode([Entry].self, from: bytes) {
            entries = Array(saved.suffix(200))
            for index in entries.indices where entries[index].inProgress {
                entries[index].inProgress = false
                entries[index].message += " (interrupted)"
            }
        }
    }

    var completed: [Entry] { entries.filter { !$0.inProgress }.reversed() }

    /// The most recent message, for the status strip.
    var latest: Entry? { entries.last }

    func observe(_ snapshots: [Snapshot]) {
        for snapshot in snapshots {
            let previous = known[snapshot.id]
            known[snapshot.id] = snapshot
            guard !snapshot.status.isEmpty,
                  previous?.status != snapshot.status || previous?.busy != snapshot.busy else { continue }
            record(driveID: snapshot.id, driveName: snapshot.name, message: snapshot.status, inProgress: snapshot.busy)
        }
        let current = Set(snapshots.map(\.id))
        known = known.filter { current.contains($0.key) }
        // Mounts leave the list only after a successful disconnect.
        for index in entries.indices where entries[index].inProgress && entries[index].driveID.map({ !current.contains($0) }) == true {
            entries[index].inProgress = false
            entries[index].message = "Disconnected."
            entries[index].date = Date()
        }
    }

    func observeApp(status: String, busy: Bool) {
        guard !status.isEmpty else {
            appStatus = status
            return
        }
        let changed = status != appStatus
        appStatus = status
        if changed {
            record(driveID: nil, driveName: nil, message: status, inProgress: busy)
        } else if !busy, let index = entries.lastIndex(where: { $0.driveID == nil && $0.inProgress }) {
            entries[index].inProgress = false
        }
    }

    func clearCompleted() { entries.removeAll { !$0.inProgress }; save() }

    private func record(driveID: String?, driveName: String?, message: String, inProgress: Bool) {
        // One operation's progress messages collapse into a single entry.
        if let index = entries.lastIndex(where: { $0.driveID == driveID }), entries[index].inProgress {
            entries[index].message = message
            entries[index].date = Date()
            entries[index].inProgress = inProgress
        } else {
            entries.append(Entry(driveID: driveID, driveName: driveName, message: message,
                                 date: Date(), inProgress: inProgress))
        }
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        save()
    }

    private func save() {
        guard let historyURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}

import SwiftUI

/// The design's bottom transfer strip. It appears while files transfer or a
/// mount operation runs and briefly shows the result before hiding. Anything
/// that needs attention stays in Activity › Needs attention instead.
@MainActor struct StatusStrip: View {
    @Bindable var model: AppModel
    let log: ActivityLog
    let openActivity: () -> Void
    @State private var expiredEntry: ActivityLog.Entry.ID?

    /// How long a finished operation's result stays visible.
    private static let resultDuration: Duration = .seconds(8)

    private var workingDrive: DriveModel? { model.drives.first(where: \.busy) }
    private var transfers: [TransferEntry] { model.transfers.map(\.entry).filter(\.active) }
    private var isWorking: Bool { model.busy || workingDrive != nil || !transfers.isEmpty }
    private var recentResult: ActivityLog.Entry? {
        guard let entry = log.latest, !entry.inProgress, entry.id != expiredEntry else { return nil }
        return entry
    }

    private var message: (icon: DesignIcon?, title: String, detail: String?, full: String) {
        if let active = model.transfers.first(where: { $0.entry.active }) {
            let verb = active.drive.isPaused ? "Paused" : active.entry.direction == .uploading ? "Uploading to" : "Downloading from"
            let title = "\(verb) \(active.drive.name)"
            let detail = TransferFormat.summary(transfers)
            return (active.entry.direction == .uploading ? .arrowUp : .arrowDown, title, detail, title + " · " + detail)
        }
        if let drive = workingDrive {
            return (nil, drive.status.firstLine.ifEmpty("Working…"), drive.name, drive.status)
        }
        if model.busy {
            return (nil, model.status.firstLine.ifEmpty("Loading mounts…"), nil, model.status)
        }
        if let entry = recentResult {
            let detail = [entry.driveName, RelativeTime.clock(entry.date)].compactMap { $0 }.joined(separator: " · ")
            return (.check, entry.message.firstLine, detail, entry.message)
        }
        return (nil, "", nil, "")
    }

    var body: some View {
        ZStack {
            if isWorking || recentResult != nil { strip }
        }
        .task(id: log.latest?.id) {
            guard let id = log.latest?.id else { return }
            try? await Task.sleep(for: Self.resultDuration)
            if !Task.isCancelled { expiredEntry = id }
        }
    }

    private var strip: some View {
        let message = message
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                if let icon = message.icon {
                    Icon(icon, size: 14).foregroundStyle(isWorking ? Palette.accent : Palette.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(message.title).font(Typography.bodyMedium).foregroundStyle(Palette.primary).lineLimit(1)
                if let detail = message.detail, !detail.isEmpty {
                    Text(detail).font(Typography.callout).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !transfers.isEmpty {
                    Button { Task { await model.setAllPaused(!model.allPaused) } } label: {
                        Icon(model.allPaused ? .sync : .pause, size: 14)
                    }
                    .buttonStyle(IconButtonStyle(size: 24, filled: true))
                    .help(model.allPaused ? "Resume syncing" : "Pause syncing")
                }
            }
            .help(message.full)
            // Only measured transfers get a bar; operations without a total show the spinner.
            if isWorking, let fraction = TransferFormat.fraction(transfers) {
                ProgressBar(value: fraction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Palette.subtle)
        .overlay(alignment: .top) { Hairline() }
        .contentShape(Rectangle())
        .onTapGesture(perform: openActivity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
        .accessibilityAction(named: "Show Activity", openActivity)
    }
}

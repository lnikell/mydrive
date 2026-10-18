import SwiftUI

/// The design's bottom "transfer strip". Per-file transfer progress is not
/// reported yet, so it shows the current mount operation, or the latest result,
/// together with saved-mount issues and retained local work.
@MainActor struct StatusStrip: View {
    @Bindable var model: AppModel
    let log: ActivityLog
    let showRetainedWork: () -> Void
    let showLoadIssues: () -> Void
    let openActivity: () -> Void

    private var workingDrive: DriveModel? { model.drives.first(where: \.busy) }
    private var transfers: [TransferEntry] { model.transfers.map(\.entry).filter(\.active) }
    private var isWorking: Bool { model.busy || workingDrive != nil || !transfers.isEmpty }

    var isVisible: Bool {
        isWorking || log.latest != nil || !model.status.isEmpty
            || !model.loadIssues.isEmpty || !model.retainedWork.isEmpty
    }

    private var message: (title: String, detail: String?, full: String) {
        if let active = model.transfers.first(where: { $0.entry.active }) {
            let verb = active.drive.isPaused ? "Paused" : active.entry.direction == .uploading ? "Uploading to" : "Downloading from"
            let title = "\(verb) \(active.drive.name)"
            let detail = TransferFormat.summary(transfers)
            return (title, detail, title + " · " + detail)
        }
        if let drive = workingDrive {
            return (drive.status.firstLine.ifEmpty("Working…"), drive.name, drive.status)
        }
        if model.busy {
            return (model.status.firstLine.ifEmpty("Loading mounts…"), nil, model.status)
        }
        if let entry = log.latest {
            let detail = [entry.driveName, RelativeTime.clock(entry.date)].compactMap { $0 }.joined(separator: " · ")
            return (entry.message.firstLine, detail, entry.message)
        }
        return (model.status.firstLine, nil, model.status)
    }

    var body: some View {
        if isVisible {
            let message = message
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Icon(.info, size: 14).foregroundStyle(Palette.secondary)
                    }
                    Text(message.title).font(Typography.bodyMedium).foregroundStyle(Palette.primary).lineLimit(1)
                    if let detail = message.detail, !detail.isEmpty {
                        Text(detail).font(Typography.callout).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !transfers.isEmpty {
                        Button { Task { await model.setAllPaused(!model.allPaused) } } label: {
                            Icon(model.allPaused ? .sync : .pause, size: 14)
                        }.buttonStyle(IconButtonStyle()).help(model.allPaused ? "Resume syncing" : "Pause syncing")
                    }
                    if !model.retainedWork.isEmpty {
                        Button("Show Retained Work…", action: showRetainedWork).buttonStyle(CardButtonStyle())
                    }
                    if !model.loadIssues.isEmpty {
                        Button("Saved Mount Issues…", action: showLoadIssues).buttonStyle(CardButtonStyle())
                    }
                }
                .help(message.full)
                if isWorking { ProgressBar(value: TransferFormat.fraction(transfers)) }
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
}

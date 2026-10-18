import SwiftUI

@MainActor @Observable private final class LibraryModel {
    struct Row: Identifiable {
        let drive: DriveModel
        let file: LibraryEntry
        var id: String { drive.id + ":" + file.id }
    }
    var rows: [Row] = []
    var loading = false
    var error = ""
    private var cursors: [String: String] = [:]
    private var generations: [String: Int64] = [:]
    private var finished: Set<String> = []
    var hasMore: Bool { !cursors.isEmpty }

    func load(drives: [DriveModel], scope: LibraryScope, reset: Bool) async {
        guard !loading else { return }
        loading = true; error = ""
        defer { loading = false }
        if reset { rows = []; cursors = [:]; generations = [:]; finished = [] }
        for drive in drives where drive.isRegistered && !drive.isPaused && !finished.contains(drive.id) {
            do {
                let page = try await drive.library(scope: scope, afterID: cursors[drive.id], generation: generations[drive.id])
                rows += page.entries.map { Row(drive: drive, file: $0) }
                generations[drive.id] = page.generation
                cursors[drive.id] = page.nextID
                if page.nextID == nil { finished.insert(drive.id) }
            } catch is CancellationError { return }
            catch {
                self.error = "\(drive.name): \(error.localizedDescription) Refresh to reload the current file list."
            }
        }
    }
}

/// The same toolbar, table, row height, icons and empty states as All Mounts.
/// The list describes known Catalog observations; it does not crawl the NAS.
@MainActor struct LibraryPane: View {
    @Bindable var model: AppModel
    let scope: LibraryScope
    @State private var library = LibraryModel()
    @State private var query = ""
    @State private var ascending = true
    @State private var selection: String?
    @State private var actionError = ""

    private var title: String { scope == .onlineOnly ? "Online-only" : "Kept Offline" }
    private var visible: [LibraryModel.Row] {
        library.rows.filter { row in
            query.isEmpty || [row.file.name, row.file.path, row.drive.name].contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { ascending ? $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending :
            $0.file.path.localizedStandardCompare($1.file.path) == .orderedDescending }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: title, detail: library.rows.isEmpty ? nil : "\(library.rows.count)") {
                FilterField(prompt: "Filter files", text: $query)
                Button { reload() } label: { Icon(.sync, size: 15) }
                    .buttonStyle(IconButtonStyle()).disabled(library.loading)
                    .help("Refresh known files")
            }
            if library.loading && library.rows.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.rows.isEmpty && !library.hasMore {
                EmptyState(title: title + " files", message: emptyMessage) {
                    IconTile(icon: scope == .onlineOnly ? .cloud : .pin)
                } actions: {
                    Button("Refresh", action: reload).buttonStyle(CardButtonStyle())
                }
            } else {
                HStack(spacing: 0) {
                    Button { ascending.toggle() } label: {
                        HStack(spacing: 4) { Text("Name"); Icon(.chevronDown, size: 11).rotationEffect(.degrees(ascending ? 0 : 180)) }
                    }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Mount").frame(width: 150, alignment: .leading)
                    Text("Size").frame(width: 90, alignment: .leading)
                    Text("Status").frame(width: 160, alignment: .leading)
                    Color.clear.frame(width: 56, height: 1)
                }
                .font(Typography.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 20).frame(height: 30).overlay(alignment: .bottom) { Hairline() }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { row in fileRow(row) }
                        if library.hasMore {
                            Button(library.loading ? "Loading…" : "Load More") {
                                Task { await library.load(drives: model.drives, scope: scope, reset: false) }
                            }.buttonStyle(CardButtonStyle()).padding(16).disabled(library.loading)
                        }
                    }
                }
            }
            if !library.error.isEmpty {
                Text(library.error).font(Typography.callout).foregroundStyle(Palette.orange)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: model.drives.map(\.id)) { await library.load(drives: model.drives, scope: scope, reset: true) }
        .alert("File Operation", isPresented: Binding(get: { !actionError.isEmpty }, set: { if !$0 { actionError = "" } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError) }
    }

    private var emptyMessage: String {
        if model.allPaused { return "Syncing is paused. Resume a mount to refresh its file list. Local files remain available in Finder." }
        if !library.error.isEmpty { return "The file list could not be loaded. Check the mount connection and try again." }
        return scope == .onlineOnly
            ? "Known files that download when opened appear here. Browse a mount in Finder to discover its files."
            : "Choose Keep Downloaded on a file, folder or mount to keep it on this Mac. Selections appear here while Finder downloads their contents."
    }

    private func fileRow(_ row: LibraryModel.Row) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(icon: row.file.folder ? .folder : .doc, size: 30, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.file.path.isEmpty ? row.drive.name : row.file.name).font(Typography.bodyMedium).foregroundStyle(Palette.primary)
                    Text(row.file.path.ifEmpty("Entire mount")).font(Typography.mono).foregroundStyle(Palette.secondary)
                }.lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(row.drive.name).frame(width: 150, alignment: .leading)
            Text(row.file.folder ? "—" : ByteCountFormatter.string(fromByteCount: row.file.size, countStyle: .file))
                .frame(width: 90, alignment: .leading)
            Label { Text(row.file.downloaded == true ? "Downloaded" : row.file.keptOffline ? "Keep requested" : "Online-only") }
                icon: { Icon(row.file.keptOffline ? .pin : .cloud, size: 13) }
                .frame(width: 160, alignment: .leading)
            MenuButton(entries: {
                [.item("Show in Finder", image: MenuBuilder.icon(.folder), action: { perform(.showFinder, row) }),
                 .item("Keep Downloaded", image: MenuBuilder.icon(.pin), enabled: !row.file.keptOffline,
                       action: { perform(.keepDownloaded, row) }),
                 .item("Free Up Space", image: MenuBuilder.icon(.cloud), action: { perform(.freeUpSpace, row) })]
            }) { _ in Icon(.ellipsis, size: 15) }.buttonStyle(.plain).frame(width: 56, alignment: .trailing)
        }
        .font(Typography.callout).foregroundStyle(Palette.secondary)
        .padding(.horizontal, 20).frame(height: 52)
        .background(selection == row.id ? Palette.accentSoft : .clear)
        .overlay(alignment: .bottom) { Hairline() }.contentShape(Rectangle())
        .onTapGesture(count: 2) { perform(.showFinder, row) }
        .simultaneousGesture(TapGesture().onEnded { selection = row.id })
    }

    private func reload() { Task { await library.load(drives: model.drives, scope: scope, reset: true) } }

    private func perform(_ action: LibraryAction, _ row: LibraryModel.Row) {
        Task {
            do {
                try await row.drive.perform(action, itemID: row.file.id)
                if action != .showFinder { await library.load(drives: model.drives, scope: scope, reset: true) }
            } catch { actionError = error.localizedDescription }
        }
    }
}

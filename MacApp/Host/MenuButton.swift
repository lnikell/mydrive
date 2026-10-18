import AppKit
import SwiftUI

/// A native menu described in SwiftUI terms. The design's Add menu and row
/// "…" menus are standard macOS menus opened from custom-styled buttons.
enum MenuEntry {
    case header(String)
    case item(String, image: NSImage? = nil, key: String = "", enabled: Bool = true,
              tooltip: String? = nil, action: () -> Void)
    case submenu(String, image: NSImage? = nil, entries: [MenuEntry])
    case separator
}

@MainActor private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("ActionMenuItem is not archived") }

    @objc private func run() { handler() }
}

@MainActor enum MenuBuilder {
    static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case let .header(title):
                menu.addItem(.sectionHeader(title: title))
            case let .item(title, image, key, enabled, tooltip, action):
                let item = ActionMenuItem(title: title, key: key, handler: action)
                item.image = image
                item.isEnabled = enabled
                item.toolTip = tooltip
                menu.addItem(item)
            case let .submenu(title, image, entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = image
                item.submenu = Self.menu(entries)
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    /// A template icon from the design set, sized for a menu row.
    static func icon(_ icon: DesignIcon, size: CGFloat = 16) -> NSImage {
        let image = (IconLibrary.image(icon).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    /// The coloured "Drive Icon" badge, rendered for a menu row.
    static func badge(_ kind: MountKind, size: CGFloat = 18) -> NSImage? {
        let renderer = ImageRenderer(content: DriveBadge(kind: kind, size: size, style: .solid).padding(1))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

/// Keeps a reference to the AppKit view behind a SwiftUI button so a menu can
/// open directly below it.
@MainActor final class MenuAnchor {
    fileprivate weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let point = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// A button that opens a native menu. While the menu is open the label keeps
/// its pressed appearance, as in the design's Add button states.
struct MenuButton<Label: View>: View {
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: (_ open: Bool) -> Label
    @State private var anchor = MenuAnchor()
    @State private var open = false

    var body: some View {
        Button {
            open = true
            let menu = MenuBuilder.menu(entries())
            // Let the pressed state render before the menu's modal tracking starts.
            DispatchQueue.main.async {
                anchor.popUp(menu)
                open = false
            }
        } label: {
            label(open)
        }
        .background(MenuAnchorView(anchor: anchor))
    }
}

/// The design's "Button/Add": opens the Add menu with mount types, Tailscale
/// peers and Connect to URL.
struct AddMenuButton: View {
    let addSMB: () -> Void
    let connectToURL: () -> Void

    var body: some View {
        MenuButton(entries: { AddMenu.entries(addSMB: addSMB, connectToURL: connectToURL) }) { open in
            HStack(spacing: 6) {
                Icon(.plus, size: 15)
                Text("Add")
            }
            .modifier(AccentChrome(pressed: open))
        }
        .buttonStyle(.plain)
        .help("Add a mount")
        .accessibilityLabel("Add")
    }
}

enum AddMenu {
    @MainActor static func entries(addSMB: @escaping () -> Void, connectToURL: @escaping () -> Void) -> [MenuEntry] {
        var entries: [MenuEntry] = [.header("New mount")]
        for kind in MountKind.addMenuOrder {
            entries.append(.item(kind.addTitle, image: MenuBuilder.badge(kind), key: kind == .smb ? "n" : "",
                                 enabled: kind.isAvailable,
                                 tooltip: kind.isAvailable ? nil : "\(kind.title) mounts aren't available yet.",
                                 action: kind == .smb ? addSMB : {}))
        }
        entries += [
            .separator,
            .submenu(MountKind.tailscale.addTitle, image: MenuBuilder.badge(.tailscale), entries: [
                .header("On your tailnet"),
                .item("Tailscale discovery isn't available yet", enabled: false, action: {}),
                .separator,
                .item("Scan again", image: MenuBuilder.icon(.sync, size: 15), enabled: false,
                      tooltip: "Tailscale discovery isn't available yet.", action: {})
            ]),
            .separator,
            .item("Connect to URL…", image: MenuBuilder.icon(.globe), key: "k", action: connectToURL)
        ]
        return entries
    }
}

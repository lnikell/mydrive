import AppKit
import SwiftUI

/// Colour tokens from the Figma "macOS" variable collection. Each token has a
/// light and a dark value and follows the system appearance.
enum Palette {
    static let window = dynamic(light: gray(1), dark: hex(0x1E1E1E))
    static let sidebar = dynamic(light: hex(0xF3F3F5), dark: hex(0x28282A))
    static let subtle = dynamic(light: hex(0xF8F8FA), dark: hex(0x232325))
    static let card = dynamic(light: gray(1), dark: hex(0x2C2C2E))
    static let control = dynamic(light: gray(0, 0.05), dark: gray(1, 0.08))
    static let hover = dynamic(light: gray(0, 0.035), dark: gray(1, 0.05))
    static let selected = dynamic(light: gray(0, 0.07), dark: gray(1, 0.10))
    static let track = dynamic(light: gray(0, 0.08), dark: gray(1, 0.12))

    static let primary = dynamic(light: gray(0, 0.86), dark: gray(1, 0.88))
    static let secondary = dynamic(light: gray(0, 0.5), dark: gray(1, 0.55))
    static let tertiary = dynamic(light: gray(0, 0.28), dark: gray(1, 0.28))
    static let onAccent = Color.white

    static let separator = dynamic(light: gray(0, 0.09), dark: gray(1, 0.09))
    static let strongSeparator = dynamic(light: gray(0, 0.14), dark: gray(1, 0.16))

    /// The design's accent is the system blue, so it follows the user's accent colour.
    static let accent = Color.accentColor
    static let accentSoft = dynamic(
        light: NSColor.controlAccentColor.withAlphaComponent(0.10),
        dark: NSColor.controlAccentColor.withAlphaComponent(0.20))

    static let green = dynamic(light: hex(0x28CD41), dark: hex(0x32D74B))
    static let greenSoft = dynamic(light: hex(0x28CD41, 0.12), dark: hex(0x32D74B, 0.18))
    static let orange = dynamic(light: hex(0xFF9500), dark: hex(0xFF9F0A))
    static let red = dynamic(light: hex(0xFF3B30), dark: hex(0xFF453A))
    static let purple = dynamic(light: hex(0xAF52DE), dark: hex(0xBF5AF2))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
}

/// The Figma "macOS/…" text styles, mapped to the matching macOS text styles.
enum Typography {
    static let body = Font.body                                   // 13 regular
    static let bodyMedium = Font.body.weight(.medium)             // 13 medium
    static let headline = Font.body.weight(.semibold)             // 13 semibold
    static let callout = Font.callout                             // 12 regular
    static let calloutMedium = Font.callout.weight(.medium)       // 12 medium
    static let subheadline = Font.subheadline                     // 11 regular
    static let section = Font.subheadline.weight(.semibold)       // 11 semibold
    static let chip = Font.caption.weight(.semibold)              // 10 semibold
    static let title3 = Font.title3.weight(.semibold)             // 15 semibold
    static let title2 = Font.title2.weight(.semibold)             // 17 semibold
    static let mono = Font.system(.subheadline, design: .monospaced)
}

// MARK: - Icons

/// The design's 24 pt, 1.5-stroke icon set, bundled as SVG in Resources/Icons.
enum DesignIcon: String {
    case activity, arrowDown = "arrow-down", arrowUp = "arrow-up", bucket, check
    case chevronDown = "chevron-down", chevronRight = "chevron-right", clock, cloud, doc, eject
    case ellipsis, folder, globe, info, key, lock, pause, pin, plus, power, search, server
    case settings, sync, tailnet, terminal, trash, warning
}

@MainActor enum IconLibrary {
    private static var cache: [DesignIcon: NSImage] = [:]

    static func image(_ icon: DesignIcon) -> NSImage {
        if let image = cache[icon] { return image }
        let image = Bundle.main.url(forResource: icon.rawValue, withExtension: "svg", subdirectory: "Icons")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = true
        cache[icon] = image
        return image
    }
}

struct Icon: View {
    let icon: DesignIcon
    var size: CGFloat = 16

    init(_ icon: DesignIcon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(nsImage: IconLibrary.image(icon))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Mount kinds and the Drive Icon component

/// Protocols and peers from the Figma "Drive Icon — Protocol × Style" component.
/// Only SMB is backed by a working connection today.
enum MountKind: String, CaseIterable, Identifiable, Hashable {
    case smb, sftp, webDAV, s3, tailscale

    var id: String { rawValue }
    /// Sidebar order from the design.
    static let protocols: [MountKind] = [.smb, .s3, .sftp, .webDAV]
    /// Add menu order from the design.
    static let addMenuOrder: [MountKind] = [.smb, .sftp, .webDAV, .s3]

    var title: String {
        switch self {
        case .smb: "SMB"
        case .sftp: "SFTP"
        case .webDAV: "WebDAV"
        case .s3: "S3"
        case .tailscale: "Tailscale"
        }
    }

    var chipTitle: String { self == .webDAV ? "WEBDAV" : title }

    var addTitle: String {
        switch self {
        case .smb: "SMB / Samba share…"
        case .sftp: "SFTP server…"
        case .webDAV: "WebDAV server…"
        case .s3: "S3-compatible bucket…"
        case .tailscale: "Tailscale peer"
        }
    }

    var isAvailable: Bool { self == .smb }

    var icon: DesignIcon {
        switch self {
        case .smb: .server
        case .sftp: .terminal
        case .webDAV: .globe
        case .s3: .bucket
        case .tailscale: .tailnet
        }
    }

    fileprivate var gradient: (UInt32, UInt32) {
        switch self {
        case .smb: (0x4C9BFF, 0x0A63E8)
        case .sftp: (0x4ADE9A, 0x13A15E)
        case .webDAV: (0xC189FF, 0x8A45E6)
        case .s3: (0xFFB340, 0xF27A0C)
        case .tailscale: (0x55555C, 0x1F1F23)
        }
    }

    fileprivate var tint: UInt32 {
        switch self {
        case .smb: 0x007AFF
        case .sftp: 0x1AAE67
        case .webDAV: 0x9A55E8
        case .s3: 0xF28A0C
        case .tailscale: 0x8E8E93
        }
    }
}

struct DriveBadge: View {
    enum Style { case solid, soft }
    let kind: MountKind
    var size: CGFloat = 30
    var style: Style = .soft

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(4, size * 0.3), style: .continuous)
        ZStack {
            switch style {
            case .solid:
                shape.fill(LinearGradient(colors: [Color(nsColor: Palette.hex(kind.gradient.0)),
                                                   Color(nsColor: Palette.hex(kind.gradient.1))],
                                          startPoint: .top, endPoint: .bottom))
                    .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: max(0.4, size * 0.025)))
                    .shadow(color: .black.opacity(0.12), radius: size * 0.025, y: size * 0.0125)
                Icon(kind.icon, size: size * 0.55).foregroundStyle(.white)
            case .soft:
                shape.fill(Color(nsColor: Palette.hex(kind.tint, 0.13)))
                Icon(kind.icon, size: size * 0.55).foregroundStyle(Color(nsColor: Palette.hex(kind.tint)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

/// "Button/Add": accent fill, 28 pt high, 7 pt radius, 12 pt side padding.
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var radius: CGFloat = 7
    var horizontalPadding: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(AccentChrome(pressed: configuration.isPressed, height: height,
                                                  radius: radius, horizontalPadding: horizontalPadding))
    }
}

/// The accent button's appearance, also used by menu buttons that stay pressed while open.
struct AccentChrome: ViewModifier {
    var pressed: Bool
    var height: CGFloat = 28
    var radius: CGFloat = 7
    var horizontalPadding: CGFloat = 12
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(Typography.bodyMedium)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.accent)
                    .overlay {
                        // Hover lightens 12 %; pressed (and an open menu) darkens 18 %.
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(pressed ? Color.black.opacity(0.18) : Color.white.opacity(hovering ? 0.12 : 0))
                    }
            }
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
    }
}

/// Bordered card buttons ("Mount…", "Resolve…", "Check Now", "Clear Filter").
struct CardButtonStyle: ButtonStyle {
    var height: CGFloat = 24
    var radius: CGFloat = 7
    var horizontalPadding: CGFloat = 10
    var role: ButtonRole?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.bodyMedium)
            .foregroundStyle(role == .destructive ? Palette.red : Palette.primary)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.card)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(configuration.isPressed ? Palette.selected : .clear))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Palette.strongSeparator, lineWidth: 1))
            }
            .shadow(color: .black.opacity(0.05), radius: 0.5, y: 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// Square, borderless toolbar and row buttons with a hover fill.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var filled = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(configuration.isPressed ? Palette.selected :
                        (hovering || filled ? Palette.control : .clear)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
    }
}

struct Chip: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Typography.chip)
            .tracking(0.1)
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Palette.strongSeparator, lineWidth: 1))
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true) }
}

struct ProgressBar: View {
    var value: Double?
    var height: CGFloat = 4
    var tint: Color = Palette.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if let value {
                    Capsule().fill(tint).frame(width: proxy.size.width * min(max(value, 0), 1))
                } else {
                    // Indeterminate: a segment sweeps across while work has no measurable total.
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let width = proxy.size.width * 0.3
                        Capsule().fill(tint)
                            .frame(width: width)
                            .offset(x: (proxy.size.width + width) * phase - width)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(value.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// The design's custom segmented control: a control-filled track with a raised card segment.
struct SegmentedPicker<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var enabled = true
        var id: String { title }
    }

    @Binding var selection: Value
    let segments: [Segment]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let selected = segment.value == selection
                Button { selection = segment.value } label: {
                    Text(segment.title)
                        .font(Typography.bodyMedium)
                        .foregroundStyle(selected ? Palette.primary : Palette.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Palette.card : .clear)
                            .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!segment.enabled)
                .opacity(segment.enabled ? 1 : 0.45)
                .help(segment.enabled ? "" : "Per-file transfer tracking isn't available yet.")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.control))
    }
}

/// A search field styled like the design's "Filter mounts" control.
struct FilterField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Icon(.search, size: 14).foregroundStyle(Palette.tertiary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Palette.tertiary))
                .textFieldStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(Palette.primary)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 220, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.control))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Palette.accent.opacity(focused ? 0.6 : 0), lineWidth: 2))
    }
}

/// Section and group headers: 11 pt semibold labels on the subtle background.
struct GroupHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var height: CGFloat = 30
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Typography.section).foregroundStyle(Palette.secondary)
            if let count { Text("\(count)").font(Typography.subheadline).foregroundStyle(Palette.tertiary) }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(height: height)
        .background(Palette.subtle)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

extension GroupHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, height: CGFloat = 30) {
        self.init(title: title, count: count, height: height) { EmptyView() }
    }
}

/// A text-only accent action inside group headers ("Pause", "Clear", "Show all").
struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Typography.subheadline.weight(.medium))
            .foregroundStyle(Palette.accent)
    }
}

struct Hairline: View {
    var color: Color = Palette.separator
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// The 52 pt toolbar strip that sits at the top of each content pane.
struct PaneToolbar<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Typography.headline).foregroundStyle(Palette.primary)
            if let detail { Text(detail).font(Typography.headline).foregroundStyle(Palette.tertiary) }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
    }
}

/// Centered empty-state stack shared by the first-launch, no-results and placeholder screens.
struct EmptyState<Icon: View, Actions: View>: View {
    let title: String
    let message: String
    var titleFont: Font = Typography.title3
    var messageWidth: CGFloat = 380
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            icon()
            Text(title).font(titleFont).foregroundStyle(Palette.primary).padding(.top, 16)
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: messageWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            actions().padding(.top, 18)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IconTile: View {
    let icon: DesignIcon
    var size: CGFloat = 64
    var radius: CGFloat = 18
    var fill: Color = Palette.control
    var tint: Color = Palette.secondary

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(Icon(icon, size: size * 0.44).foregroundStyle(tint))
    }
}

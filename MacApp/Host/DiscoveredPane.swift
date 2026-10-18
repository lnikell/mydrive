import SwiftUI

@MainActor struct DiscoveredPane: View {
    let mount: () -> Void
    @State private var discovery = DiscoveryService.shared
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(title: "Discovered", detail: discovery.peers.isEmpty ? nil : "\(discovery.peers.count)") {
                FilterField(prompt: "Filter servers", text: $query)
                Button { discovery.start(); discovery.scanTailnet() } label: { Icon(.sync, size: 15) }
                    .buttonStyle(IconButtonStyle()).disabled(discovery.scanning).help("Scan again")
            }
            if discovery.peers.isEmpty {
                EmptyState(title: "No discovered servers", message: discovery.status) { IconTile(icon: .tailnet) } actions: {
                    Button("Scan Again") { discovery.start(); discovery.scanTailnet() }.buttonStyle(CardButtonStyle()).disabled(discovery.scanning)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(discovery.peers.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query) }) { peer in
                            DiscoveredPeerRow(peer: peer, mount: mount)
                        }
                    }
                }
            }
        }.task { discovery.start() }
    }
}

@MainActor struct DiscoveredPeerRow: View {
    let peer: DiscoveredPeer
    let mount: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            DriveBadge(kind: peer.tailnet ? .tailscale : .smb, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(Typography.bodyMedium).foregroundStyle(Palette.primary)
                Text(peer.address).font(Typography.mono).foregroundStyle(Palette.secondary)
            }.lineLimit(1)
            Spacer()
            Text(peer.os).font(Typography.callout).foregroundStyle(Palette.secondary)
            Button("Mount…") { DiscoveryService.shared.pendingAddress = peer.address; mount() }
                .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
        }.padding(.horizontal, 20).frame(height: 52).overlay(alignment: .bottom) { Hairline() }
    }
}

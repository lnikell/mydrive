import AppKit
import Foundation
import Observation

struct DiscoveredPeer: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let os: String
    let tailnet: Bool
}

/// Bonjour advertises actual SMB services. Tailscale contributes reachable peer
/// addresses from its supported local CLI; sign-in still verifies share access.
@MainActor @Observable final class DiscoveryService: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    static let shared = DiscoveryService()
    private(set) var peers: [DiscoveredPeer] = []
    private(set) var status = "Discovery is off"
    private(set) var scanning = false
    var pendingAddress: String?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var scan: Task<Void, Never>?
    private var tailnetPeers: [DiscoveredPeer] = []
    private var localPeers: [String: DiscoveredPeer] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
    }

    func scanTailnet() {
        guard !scanning else { return }
        scanning = true; status = "Finding Tailscale peers…"
        scan = Task {
            defer { scanning = false }
            let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                status = "Tailscale isn't installed. Local SMB discovery is available."; return
            }
            do {
                let output = DiscoveryOutput()
                try await HelperOperation.run(executable: URL(fileURLWithPath: executable), arguments: ["status", "--json"],
                    input: Data(), idleTimeout: 8) { frame in try await output.append(frame) }
                let result = try JSONDecoder().decode(TailscaleStatus.self, from: await output.bytes)
                guard result.BackendState == "Running" else {
                    tailnetPeers = []; publish(); status = "Open Tailscale and connect to your tailnet."; return
                }
                tailnetPeers = (result.Peer ?? [:]).compactMap { key, peer in
                    guard peer.Online == true, let address = peer.TailscaleIPs?.first else { return nil }
                    return DiscoveredPeer(id: "tailnet-" + key, name: peer.HostName ?? peer.DNSName ?? address,
                        address: address, os: peer.OS ?? "", tailnet: true)
                }
                publish()
                status = "Tailscale connected · \(tailnetPeers.count) online peers"
            } catch is CancellationError { }
            catch { status = "Tailscale status couldn't be read. Open Tailscale and check that its local CLI is available." }
        }
    }

    func stopTailnet() {
        scan?.cancel(); scan = nil
        tailnetPeers = []; status = "Tailscale discovery is off"; publish()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 1000 else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        localPeers.removeValue(forKey: service.name + ":" + service.domain)
        publish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0, sender.port <= 65535 else { return }
        let id = sender.name + ":" + sender.domain
        localPeers[id] = DiscoveredPeer(id: id, name: sender.name, address: "\(host):\(sender.port)", os: "SMB", tailnet: false)
        publish()
    }

    private func publish() {
        peers = (Array(localPeers.values) + tailnetPeers).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct TailscaleStatus: Decodable {
        let BackendState: String
        let Peer: [String: PeerStatus]?
    }
    private struct PeerStatus: Decodable {
        let HostName: String?
        let DNSName: String?
        let TailscaleIPs: [String]?
        let OS: String?
        let Online: Bool?
    }
}

private actor DiscoveryOutput {
    var bytes = Data()
    func append(_ frame: Data) throws {
        guard bytes.count + frame.count + 1 <= 2_097_152 else { throw SMBClientError.invalidResponse }
        bytes.append(frame); bytes.append(10)
    }
}

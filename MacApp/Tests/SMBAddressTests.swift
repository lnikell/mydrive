import Foundation

@main struct SMBAddressTests {
    private static func check(_ value: Bool) throws {
        if !value { throw NSError(domain: "SMBAddressTests", code: 1) }
    }
    private static func rejected(_ server: String, _ share: String = "Shared") throws {
        do {
            _ = try SMBAddress(server: server, share: share)
            throw NSError(domain: "SMBAddressTests", code: 2)
        } catch let error as SMBAddressError {
            // Typed errors must not repeat a credential, hostname or share.
            try check(!error.localizedDescription.contains("do-not-echo-secret"))
        }
    }
    static func main() throws {
        for (server, expected) in [("nas.local", "nas.local:445"), ("NAS.LOCAL:1445", "nas.local:1445"),
            ("NAS_BOX", "nas_box:445"), ("_NAS_.local_:1445", "_nas_.local_:1445"),
            ("192.0.2.10", "192.0.2.10:445"), ("192.0.2.10:65535", "192.0.2.10:65535"),
            ("[2001:db8::1]", "[2001:db8::1]:445"), ("[2001:DB8::1]:1445", "[2001:db8::1]:1445")] {
            try check(try SMBAddress(server: server, share: "Shared").endpoint == expected)
        }
        print("PASS DNS/SMB underscore labels, IPv4 and bracketed IPv6 use default445 or an explicit bounded port")
        let name = "Partag\u{e9} — \u{65e5}\u{672c}"
        let address = try SMBAddress(server: "smb://nas.local/Partag%C3%A9%20%E2%80%94%20%E6%97%A5%E6%9C%AC", share: "")
        try check(address.endpoint == "nas.local:445" && address.share.utf8.elementsEqual(name.utf8))
        try check(try SMBAddress(server: "smb://[2001:db8::1]:1445/Shared", share: "Shared").endpoint == "[2001:db8::1]:1445")
        try check(try SMBAddress(server: "smb://nas.local/", share: "Shared").share == "Shared")
        try check(try SMBAddress(server: "smb://nas.local/100%252F", share: "").share == "100%2F")
        try check(try SMBAddress(server: "smb://nas.local/Shared/", share: "").share == "Shared")
        try check(try SMBAddress(server: "smb://NAS_BOX/Partag%C3%A9/", share: "Partag\u{e9}").share == "Partag\u{e9}")
        try check(try SMBAddress(server: "smb://nas.local/100%252F/", share: "").share == "100%2F")
        print("PASS one URL share and optional single trailing slash decode once, preserve Unicode bytes and combine only matching manual shares")
        for server in ["", "nas.local:", "nas.local:0", "nas.local:65536", "nas.local:-1", "nas.local:+445", "nas.local:port",
            "[2001:db8::1", "[2001:db8::xyz]", "[2001:db8::1]extra", "2001:db8::1", "999.0.2.1", "bad..local", "-nas.local",
            "smb://nas.local/Shared/deep", "smb://nas.local//", "smb://nas.local/Shared//", "smb://nas.local//Shared/",
            "smb://nas.local/%2F/", "smb://nas.local/Shared%2F/", "smb://nas.local/%2F", "smb://nas.local/%5c", "smb://nas.local/%2e%2e",
            "smb://nas.local/Shared?query", "smb://nas.local/Shared#fragment", "smb://nas.local/%ZZ", "https://nas.local/Shared", "nas.local/Shared",
            "nas.local\n", "smb://nas.local/%00"] {
            try rejected(server)
        }
        var credentialURL = URLComponents()
        credentialURL.scheme = "smb"; credentialURL.host = "nas.local"; credentialURL.path = "/Shared"
        credentialURL.user = "user"; credentialURL.password = "do-not-echo-secret"
        try rejected(credentialURL.string!)
        try rejected("nas.local", ""); try rejected("nas.local", " "); try rejected("nas.local", ".."); try rejected("nas.local", "A/B")
        try rejected("nas.local", "A\\B"); try rejected("nas.local", "do-not-echo-secret\n")
        try rejected(String(repeating: "x", count: 4097))
        try rejected(String(repeating: "_", count: 64) + ".local")
        try rejected("nas-.local"); try rejected("_nas_.bad..label")
        try rejected("nas.local", String(repeating: "x", count: 256))
        try rejected("smb://nas.local/Other", "Shared")
        try rejected("smb://nas.local/Caf%C3%A9", "Cafe\u{301}")
        print("PASS invalid ports, paths, encoded separators, credentials, controls, bounds and byte-distinct share conflicts fail with redacted typed errors")
    }
}

import Foundation
import Testing
@testable import CABDesktop

@Suite("SSH config and login URL discovery")
struct SSHConfigDiscoveryTests {
    @Test func discoversConcreteAliasesAndIncludesWithoutReadingIdentityFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ssh = root.appendingPathComponent(".ssh")
        let includes = ssh.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        try """
        Host *
          IdentityFile ~/.ssh/private_key
        Host primary prod-1 *.wild !excluded
        Include conf.d/*.conf
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try """
        Host nested
          HostName example.invalid
        """.write(to: includes.appendingPathComponent("servers.conf"), atomically: true, encoding: .utf8)

        let aliases = try SSHConfigDiscovery(homeDirectory: root).discover()

        #expect(aliases == ["nested", "primary", "prod-1"])
        #expect(!aliases.contains("private_key"))
    }

    @Test func officialLoginURLAcceptsOnlyOpenAIDomains() {
        let service = CABService()
        #expect(service.officialLoginURL(in: "Open https://example.com/device") == nil)
        #expect(service.officialLoginURL(in: "Open https://auth.openai.com/codex/device and enter the code")?.absoluteString == "https://auth.openai.com/codex/device")
        #expect(service.officialLoginURL(in: "Open \u{001B}[94mhttps://auth.openai.com/codex/device\u{001B}[0m now")?.absoluteString == "https://auth.openai.com/codex/device")
        #expect(service.officialLoginURL(in: "plugin warning https://chatgpt.com/backend-api/plugins/featured") == nil)
        let oauth = "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
        #expect(service.officialLoginURL(in: "Open \(oauth)")?.absoluteString == oauth)
        #expect(service.officialLoginURL(in: "https://auth.openai.com/oauth/authorize?redirect_uri=https%3A%2F%2Fevil.example%2Fcallback") == nil)
    }
}

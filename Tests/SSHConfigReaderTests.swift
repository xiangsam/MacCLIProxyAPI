import XCTest
@testable import MacCLIProxyAPI

final class SSHConfigReaderTests: XCTestCase {
    func testParsesConcreteHostsAndSkipsWildcards() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-config-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("extra")
        try """
        Host from-include
          HostName include.example.com
          User include-user
        """.write(to: included, atomically: true, encoding: .utf8)

        let config = dir.appendingPathComponent("config")
        try """
        Host *
          User default-user
          Port 2222
          IdentityFile ~/.ssh/id_ed25519

        Host *.example.com
          User wild

        Include \(included.path)

        Host dev staging
          HostName 10.0.0.8
          User samrito
          Port 22
          IdentityFile "~/.ssh/dev_key"

        Host git.example.com
          # comment only
        """.write(to: config, atomically: true, encoding: .utf8)

        let hosts = SSHConfigReader.loadImportableHosts(configURL: config, defaultUsername: "fallback")
        let aliases = hosts.map(\.alias)
        XCTAssertEqual(aliases.sorted(), ["dev", "from-include", "git.example.com", "staging"].sorted())
        XCTAssertFalse(aliases.contains { $0.contains("*") })

        let dev = try XCTUnwrap(hosts.first { $0.alias == "dev" })
        XCTAssertEqual(dev.hostName, "10.0.0.8")
        XCTAssertEqual(dev.user, "samrito")
        XCTAssertEqual(dev.port, 22)
        XCTAssertTrue(dev.identityFile.hasSuffix("/.ssh/dev_key"), dev.identityFile)

        let staging = try XCTUnwrap(hosts.first { $0.alias == "staging" })
        XCTAssertEqual(staging.hostName, "10.0.0.8")
        XCTAssertEqual(staging.user, "samrito")

        let git = try XCTUnwrap(hosts.first { $0.alias == "git.example.com" })
        XCTAssertEqual(git.hostName, "git.example.com")
        XCTAssertEqual(git.user, "default-user")
        XCTAssertEqual(git.port, 2222)
        XCTAssertTrue(git.identityFile.hasSuffix("/.ssh/id_ed25519"), git.identityFile)

        let includedHost = try XCTUnwrap(hosts.first { $0.alias == "from-include" })
        XCTAssertEqual(includedHost.hostName, "include.example.com")
        XCTAssertEqual(includedHost.user, "include-user")
        // Host * still fills port / identity when not set on the include block.
        XCTAssertEqual(includedHost.port, 2222)
    }

    func testToRemoteSSHHost() {
        let entry = SSHConfigHostEntry(
            alias: "dev",
            hostName: "10.0.0.8",
            user: "samrito",
            port: 22,
            identityFile: "/tmp/key",
            source: "~/.ssh/config"
        )
        let host = entry.toRemoteSSHHost()
        XCTAssertEqual(host.name, "dev")
        XCTAssertEqual(host.host, "10.0.0.8")
        XCTAssertEqual(host.username, "samrito")
        XCTAssertEqual(host.identityFile, "/tmp/key")
        XCTAssertTrue(host.notes.contains("~/.ssh/config"))
    }
}

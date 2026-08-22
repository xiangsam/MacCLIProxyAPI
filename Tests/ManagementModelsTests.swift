import XCTest
@testable import MacCLIProxyAPI

final class ManagementModelsTests: XCTestCase {
    func testProviderConfigParsesManagementPayload() {
        let provider = ProviderConfig(raw: [
            "name": "demo",
            "base-url": "https://api.example.com/v1",
            "api-key": "secret",
            "disabled": true,
            "priority": 10,
        ], index: 0)

        XCTAssertEqual(provider.name, "demo")
        XCTAssertEqual(provider.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(provider.apiKey, "secret")
        XCTAssertTrue(provider.disabled)
        XCTAssertEqual(provider.priority, 10)
        XCTAssertEqual(provider.listIndex, 0)
        XCTAssertFalse(provider.apiKeyFromCache)
        XCTAssertEqual(provider.deletionQuery["name"], "demo")
        let put = provider.putDictionary()
        XCTAssertEqual(put["priority"] as? Int, 10)

        let redacted = ProviderConfig(
            raw: ["name": "demo", "base-url": "https://api.example.com/v1"],
            index: 1,
            cachedAPIKey: "from-cache"
        )
        XCTAssertEqual(redacted.apiKey, "from-cache")
        XCTAssertTrue(redacted.apiKeyFromCache)
        XCTAssertEqual(redacted.listIndex, 1)
        XCTAssertEqual(redacted.priority, 0)
        XCTAssertNil(redacted.putDictionary()["priority"])
    }

    /// `codex` now covers both the OAuth subscription and any `codex-api-key` native-Responses
    /// provider, so usage rows are only readable when `auth_type` is taken into account.
    func testUsageProviderLabelSeparatesCodexAuthTypes() {
        XCTAssertEqual(UsageProviderLabel.display("codex", authType: "apikey"), "Codex API Key")
        XCTAssertEqual(UsageProviderLabel.display("codex", authType: "oauth"), "Codex 订阅")
        XCTAssertEqual(UsageProviderLabel.display("openai", authType: "oauth"), "Codex 订阅")
        XCTAssertEqual(UsageProviderLabel.display("codex"), "Codex / OpenAI")
        XCTAssertEqual(
            UsageProviderLabel.display("openai-compatible-acme", authType: "apikey"),
            "Acme"
        )
        XCTAssertEqual(UsageProviderLabel.display("claude", authType: "apikey"), "Claude")
    }

    /// A vendor spanning both config sections (chat under `openai-compatibility`, GPT under
    /// `codex-api-key`) must attribute to the *same* label on both legs, so usage groups under one
    /// provider instead of splitting. Regression: `nativeResponsesOwners` (host-derived,
    /// capitalized) and CPA's own lowercased `provider` slug used to disagree only in case --
    /// `SELECT DISTINCT` treats that as two different providers even though the `COLLATE NOCASE`
    /// filter treats them as one, so a row's own recomputed label stopped matching the value that
    /// selected it.
    func testUsageProviderLabelConvergesAcrossNativeResponsesAndCompatibilityLegs() {
        let nativeResponsesLabel = UsageProviderLabel.display(
            "codex",
            authType: "apikey",
            source: "sk-shared-key",
            nativeResponsesOwners: ["sk-shared-key": "Acme"]
        )
        let compatibilityLabel = UsageProviderLabel.display(
            "openai-compatible-acme",
            authType: "apikey"
        )
        XCTAssertEqual(nativeResponsesLabel, compatibilityLabel)
        XCTAssertEqual(nativeResponsesLabel, "Acme")
    }

    /// The label a row shows must also be the label that selects it.
    ///
    /// A `codex-api-key` native-Responses leg is `provider = 'codex'`, so filtering on the raw
    /// column listed those events under 「Codex / OpenAI」 while 「Codex API Key」 hid them — the
    /// row said one thing and the filter another. Reads the local database, so it only asserts
    /// when there is data.
    func testProviderFilterSelectsRowsByAttributedLabel() throws {
        let labels = try UsageDatabase.shared.distinctProviders(query: UsageQuery())
        try XCTSkipIf(labels.isEmpty, "本机暂无使用记录")

        for label in labels {
            var scoped = UsageQuery()
            scoped.provider = label
            scoped.pageSize = 50
            let page = try UsageDatabase.shared.events(query: scoped)
            XCTAssertFalse(page.items.isEmpty, "「\(label)」筛不出任何记录")
            for item in page.items {
                XCTAssertEqual(item.providerDisplayName, label, "行标签与筛选值不一致")
            }
        }
    }

    /// Under api-key auth `source` is the live upstream credential, so the events list must not
    /// render it verbatim; OAuth rows carry an account name, which is what makes the row readable.
    func testUsageSourceMasksCredentialsButKeepsAccounts() {
        let key = "ck_fu1p897buv40.GejtBrKAm_WjraKB51LP1sFEJcOm5Kt9f0yt_pl6JnY"
        let masked = UsageProviderLabel.maskSourceIfCredential(key, authType: "apikey")
        XCTAssertEqual(masked, "ck_fu1…6JnY")
        XCTAssertFalse(masked.contains("GejtBrKAm"))

        XCTAssertEqual(
            UsageProviderLabel.maskSourceIfCredential("user@example.com", authType: "oauth"),
            "user@example.com"
        )
        // Short keys must not leak a usable prefix.
        XCTAssertEqual(UsageProviderLabel.maskSourceIfCredential("abc123", authType: "api-key"), "••••••")
    }

    /// A whole-list PUT must not blank the keys of providers the user is not editing: CPA's GET
    /// omits `api-key`, so rows have to be refilled from the local cache first.
    func testReinjectRestoresSiblingKeysWithoutClobberingPresentOnes() {
        let section = ProviderKind.openai
        let name = "reinject-test-\(UUID().uuidString)"
        defer { ProviderSecretStore.remove(section: section, name: name, authIndex: nil) }
        ProviderSecretStore.set(section: section, name: name, authIndex: nil, apiKey: "cached-key")

        let list: [[String: Any]] = [
            ["name": name, "base-url": "https://a.example.com"],
            ["name": "other", "base-url": "https://b.example.com", "api-key": "explicit-key"],
            ["name": "unknown-provider-\(UUID().uuidString)", "base-url": "https://c.example.com"],
        ]
        let next = ProviderSecretStore.reinject(into: list, section: section)

        XCTAssertEqual(next[0]["api-key"] as? String, "cached-key")
        XCTAssertEqual(next[1]["api-key"] as? String, "explicit-key")
        XCTAssertNil(next[2]["api-key"], "no cache entry means we must not invent a key")
        // Normalized to the dual format CPA expects.
        XCTAssertEqual(
            (next[1]["api-key-entries"] as? [[String: Any]])?.first?["api-key"] as? String,
            "explicit-key"
        )
    }

    /// codex-api-key / claude-api-key / gemini-api-key rows carry no `name`, and a freshly added
    /// provider has no server `auth-index` yet, so base-url is the only usable identity.
    func testSecretCacheFallsBackToBaseURLForNamelessSections() {
        let section = ProviderKind.codex
        let base = "https://nameless-\(UUID().uuidString).example.com"
        defer { ProviderSecretStore.remove(section: section, name: nil, authIndex: nil, baseURL: base) }

        ProviderSecretStore.set(section: section, name: nil, authIndex: nil, apiKey: "dropped")
        XCTAssertNil(
            ProviderSecretStore.get(section: section, name: nil, authIndex: nil, baseURL: base),
            "without any identity there is nothing to key the cache on"
        )

        ProviderSecretStore.set(section: section, name: nil, authIndex: nil, baseURL: base, apiKey: "kept")
        XCTAssertEqual(
            ProviderSecretStore.get(section: section, name: nil, authIndex: nil, baseURL: base),
            "kept"
        )
        // Case and padding differences must still hit the same entry.
        XCTAssertEqual(
            ProviderSecretStore.get(
                section: section,
                name: nil,
                authIndex: nil,
                baseURL: " " + base.uppercased() + " "
            ),
            "kept"
        )
        XCTAssertNil(ProviderSecretStore.get(section: .claude, name: nil, authIndex: nil, baseURL: base))
    }

    /// Feeds `UsageProviderLabel.display`'s `nativeResponsesOwners` map: every stored
    /// `codex-api-key` credential's api-key, mapped to its host-derived display name. A
    /// `claude`-section secret at the same base-url must not leak in.
    func testNativeResponsesProviderNamesMapsCredentialToHostDerivedOwner() {
        let base = "https://gpt.acme-\(UUID().uuidString).example.com"
        let key = "ck_native_\(UUID().uuidString)"
        defer {
            ProviderSecretStore.remove(section: .codex, name: nil, authIndex: nil, baseURL: base)
            ProviderSecretStore.remove(section: .claude, name: nil, authIndex: nil, baseURL: base)
        }
        ProviderSecretStore.set(section: .codex, name: nil, authIndex: nil, baseURL: base, apiKey: key)
        ProviderSecretStore.set(section: .claude, name: nil, authIndex: nil, baseURL: base, apiKey: "claude-key")

        let names = ProviderSecretStore.nativeResponsesProviderNames()
        XCTAssertEqual(names[key], ProviderKind.hostDerivedDisplayName(baseURL: base))
        XCTAssertFalse(names.values.contains("claude-key"))
    }

    func testProviderInputAllowsNonSkKeys() {
        XCTAssertNoThrow(try ProviderInputValidator.validate(
            name: "compat",
            baseURL: "https://example.com/v1",
            apiKey: "my-custom-token-not-sk",
            requiresName: true
        ))
    }

    func testAuthFileInfoRequiresNameAndParsesFields() {
        let file = AuthFileInfo(raw: [
            "name": "account.json",
            "provider": "codex",
            "disabled": false,
            "priority": 2,
            "auth_index": "3",
        ])
        XCTAssertEqual(file?.name, "account.json")
        XCTAssertEqual(file?.provider, "codex")
        XCTAssertEqual(file?.priority, 2)
        XCTAssertEqual(file?.authIndex, "3")
        XCTAssertNil(AuthFileInfo(raw: ["provider": "codex"]))
    }

    func testExtractAndApplyAPIKeyEntries() {
        let fromEntries = ProviderConfig.extractAPIKey(from: [
            "api-key-entries": [
                ["api-key": "ck_test", "auth-index": "abc"],
            ],
        ])
        XCTAssertEqual(fromEntries.key, "ck_test")
        XCTAssertEqual(fromEntries.authIndex, "abc")

        var row: [String: Any] = ["name": "acme"]
        ProviderConfig.applyAPIKey(to: &row, apiKey: "ck_new")
        XCTAssertEqual(row["api-key"] as? String, "ck_new")
        let entries = row["api-key-entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?["api-key"] as? String, "ck_new")

        let provider = ProviderConfig(raw: [
            "name": "acme",
            "api-key-entries": [["api-key": "from-entries"]],
        ], index: 0)
        XCTAssertEqual(provider.apiKey, "from-entries")
        XCTAssertFalse(provider.apiKeyFromCache)
    }


}

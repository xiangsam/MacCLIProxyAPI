import Foundation

enum QuotaService {
    // MARK: - Public

    static func loadAll(client: ManagementClient) async -> [AccountQuotaSummary] {
        let files: [[String: Any]]
        do {
            let json = try await client.getJSON(path: "auth-files")
            files = normalizeAuthFiles(json)
        } catch {
            return []
        }

        let enabled = files.filter { file in
            !(boolValue(file["disabled"]) ?? false)
        }

        return await withTaskGroup(of: AccountQuotaSummary?.self) { group in
            for file in enabled {
                group.addTask {
                    await loadOne(file: file, client: client)
                }
            }
            var results: [AccountQuotaSummary] = []
            for await item in group {
                if let item { results.append(item) }
            }
            results.append(contentsOf: await loadDeepSeekAccounts(client: client))
            return results.sorted { lhs, rhs in
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                return lhs.displayName < rhs.displayName
            }
        }
    }

    static func loadOne(file: [String: Any], client: ManagementClient) async -> AccountQuotaSummary? {
        guard let provider = providerForFile(file) else { return nil }
        let name = fileName(file)
        let authIndex = normalizeAuthIndex(file["auth_index"] ?? file["authIndex"])
        // Stable id across refreshes for menu-bar provider selection.
        let id = "\(provider.rawValue)|\(name)|\(authIndex)"
        let display = displayName(file: file, provider: provider)

        guard !authIndex.isEmpty else {
            return AccountQuotaSummary(
                id: id,
                fileName: name,
                provider: provider,
                displayName: display,
                status: .error,
                plan: nil,
                metrics: [],
                error: "缺少 authIndex",
                fetchedAt: Date(),
                resetCredits: nil
            )
        }

        do {
            let payload = try await callUpstream(provider: provider, authIndex: authIndex, file: file, client: client)
            var metrics = quotaMetrics(provider: provider, payload: payload)
            var plan: String?
            var resetCredits: Int?

            if provider == .claude {
                plan = await loadClaudePlan(authIndex: authIndex, client: client)
            }
            if provider == .codex {
                resetCredits = codexResetCredits(from: payload)
                if let planType = stringValue(asRecord(payload)?["plan_type"] ?? asRecord(payload)?["planType"]) {
                    plan = planType
                }
            }
            if provider == .antigravity {
                plan = await loadAntigravityPlan(authIndex: authIndex, client: client)
            }
            if provider == .xai {
                plan = xaiPlan(from: payload)
            }

            if metrics.isEmpty {
                return AccountQuotaSummary(
                    id: id,
                    fileName: name,
                    provider: provider,
                    displayName: display,
                    status: .error,
                    plan: plan,
                    metrics: [],
                    error: "无法解析配额响应",
                    fetchedAt: Date(),
                    resetCredits: resetCredits
                )
            }

            // Ensure deterministic metric ids for list diffs.
            metrics = metrics.enumerated().map { index, metric in
                var m = metric
                if m.label.isEmpty { m.label = "限额 \(index + 1)" }
                return m
            }

            return AccountQuotaSummary(
                id: id,
                fileName: name,
                provider: provider,
                displayName: display,
                status: .success,
                plan: plan,
                metrics: metrics,
                error: nil,
                fetchedAt: Date(),
                resetCredits: resetCredits
            )
        } catch {
            return AccountQuotaSummary(
                id: id,
                fileName: name,
                provider: provider,
                displayName: display,
                status: .error,
                plan: nil,
                metrics: [],
                error: error.localizedDescription,
                fetchedAt: Date(),
                resetCredits: nil
            )
        }
    }

    // MARK: - API-key providers (DeepSeek balance)

    static func loadDeepSeekAccounts(client: ManagementClient) async -> [AccountQuotaSummary] {
        var entries: [(section: ProviderKind, row: [String: Any])] = []
        for section in [ProviderKind.openai, ProviderKind.codex] {
            do {
                let json = try await client.getJSON(path: section.managementPath)
                let rows = normalizeProviderList(json, sectionKey: section.managementPath)
                entries.append(contentsOf: rows.map { (section: section, row: $0) })
            } catch {
                continue
            }
        }

        var accounts: [AccountQuotaSummary] = []
        var seenIDs = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard isDeepSeekProvider(entry.row) else { continue }
            let config = ProviderConfig(
                raw: entry.row,
                index: index,
                cachedAPIKey: ProviderSecretStore.get(
                    section: entry.section,
                    name: entry.row["name"] as? String,
                    authIndex: (entry.row["auth-index"] as? String) ?? (entry.row["authIndex"] as? String),
                    baseURL: (entry.row["base-url"] as? String) ?? (entry.row["baseUrl"] as? String)
                )
            )
            let id = config.apiKey.isEmpty
                ? "deepseek|\(config.name)|\(config.baseURL)"
                : "deepseek|\(config.apiKey)|\(config.baseURL)"
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)
            let displayName = "DeepSeek · \(config.name)"
            guard !config.apiKey.isEmpty else {
                accounts.append(AccountQuotaSummary(
                    id: id,
                    fileName: config.name,
                    provider: .deepseek,
                    displayName: displayName,
                    status: .error,
                    plan: nil,
                    metrics: [],
                    error: "缺少 DeepSeek API Key",
                    fetchedAt: Date(),
                    resetCredits: nil
                ))
                continue
            }
            do {
                let payload = try await fetchDeepSeekBalance(apiKey: config.apiKey, baseURL: config.baseURL)
                var metrics = deepSeekMetrics(payload)
                guard !metrics.isEmpty else {
                    throw AppError("DeepSeek 余额响应为空")
                }
                metrics = metrics.enumerated().map { index, metric in
                    var m = metric
                    if m.label.isEmpty { m.label = "限额 \(index + 1)" }
                    return m
                }
                accounts.append(AccountQuotaSummary(
                    id: id,
                    fileName: config.name,
                    provider: .deepseek,
                    displayName: displayName,
                    status: .success,
                    plan: nil,
                    metrics: metrics,
                    error: nil,
                    fetchedAt: Date(),
                    resetCredits: nil
                ))
            } catch {
                accounts.append(AccountQuotaSummary(
                    id: id,
                    fileName: config.name,
                    provider: .deepseek,
                    displayName: displayName,
                    status: .error,
                    plan: nil,
                    metrics: [],
                    error: error.localizedDescription,
                    fetchedAt: Date(),
                    resetCredits: nil
                ))
            }
        }
        return accounts
    }

    private static func isDeepSeekProvider(_ row: [String: Any]) -> Bool {
        let name = (row["name"] as? String) ?? ""
        let baseURL = (row["base-url"] as? String) ?? (row["baseUrl"] as? String) ?? ""
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n.contains("deepseek") || b.contains("deepseek")
    }

    private static func deepSeekBalanceURL(baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "https://api.deepseek.com" : trimmed
        let normalized = base.hasSuffix("/") ? String(base.dropLast()) : base
        return normalized + "/user/balance"
    }

    private static func fetchDeepSeekBalance(apiKey: String, baseURL: String) async throws -> [String: Any] {
        guard let url = URL(string: deepSeekBalanceURL(baseURL: baseURL)) else {
            throw AppError("DeepSeek 余额地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("DeepSeek 余额接口无响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError("DeepSeek 余额接口 \(http.statusCode): \(text)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("DeepSeek 余额响应无效")
        }
        return object
    }

    // MARK: - Upstream call via management /api-call

    private static func callUpstream(
        provider: QuotaProvider,
        authIndex: String,
        file: [String: Any],
        client: ManagementClient
    ) async throws -> Any {
        switch provider {
        case .xai:
            return try await callXai(authIndex: authIndex, file: file, client: client)
        case .antigravity:
            return try await callAntigravity(authIndex: authIndex, file: file, client: client)
        default:
            let url = endpoint(for: provider)
            var headers = headers(for: provider)
            if provider == .codex {
                if let accountId = codexAccountId(from: file), !accountId.isEmpty {
                    headers["Chatgpt-Account-Id"] = accountId
                }
            }
            return try await apiCall(
                client: client,
                authIndex: authIndex,
                method: "GET",
                url: url,
                headers: headers,
                data: nil
            )
        }
    }

    private static func callXai(authIndex: String, file: [String: Any], client: ManagementClient) async throws -> Any {
        var mutableHeaders = headers(for: .xai)
        if let userId = xaiUserId(from: file), !userId.isEmpty {
            mutableHeaders["x-userid"] = userId
            mutableHeaders["x-grok-user-id"] = userId
        }
        let requestHeaders = mutableHeaders
        async let weekly = resultOf {
            try await apiCall(
                client: client,
                authIndex: authIndex,
                method: "GET",
                url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
                headers: requestHeaders,
                data: nil
            )
        }
        async let monthly = resultOf {
            try await apiCall(
                client: client,
                authIndex: authIndex,
                method: "GET",
                url: "https://cli-chat-proxy.grok.com/v1/billing",
                headers: requestHeaders,
                data: nil
            )
        }
        let w = await weekly
        let m = await monthly
        let wv = try? w.get()
        let mv = try? m.get()
        if wv == nil, mv == nil {
            // The upstream text says *why* — an expired OAuth token reads "Invalid or expired
            // credentials", which a generic 「配额请求失败」 hides, making it look like the quota
            // endpoint is down rather than the credential being stale.
            throw AppError(xaiFailureMessage(weekly: w, monthly: m))
        }
        return ["weekly": wv as Any, "monthly": mv as Any]
    }

    private static func resultOf<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Build the message shown when both billing reads failed.
    ///
    /// `api-call` hands the credential to the upstream as stored and only refreshes it for
    /// antigravity, so an xAI token — which lives 6 hours — 401s here whenever the core's
    /// scheduled refresh was missed, typically across a sleep. The credential is still good:
    /// a real request refreshes it and retries, which is why the fix is to use Grok once
    /// rather than to sign in again.
    static func xaiFailureMessage(weekly: Result<Any, Error>, monthly: Result<Any, Error>) -> String {
        let details = [weekly, monthly].compactMap { result -> String? in
            guard case .failure(let error) = result else { return nil }
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard let first = details.first else { return "xAI 配额请求失败" }
        let lowered = first.lowercased()
        if lowered.contains("invalid or expired") || lowered.contains("invalid_token")
            || lowered.contains("401") || lowered.contains("unauthorized")
        {
            return "xAI 凭据已过期：发起一次 Grok 对话即可让内核自动刷新，之后配额会恢复"
        }
        return "xAI 配额请求失败：\(first)"
    }

    private static func callAntigravity(authIndex: String, file: [String: Any], client: ManagementClient) async throws -> Any {
        let project = stringValue(file["project_id"] ?? file["projectId"]) ?? ""
        guard !project.isEmpty else {
            throw AppError("Antigravity 缺少 project_id")
        }
        let headers = headers(for: .antigravity)
        let urls = [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        ]
        var lastError: Error?
        for url in urls {
            do {
                let payload = try await apiCall(
                    client: client,
                    authIndex: authIndex,
                    method: "POST",
                    url: url,
                    headers: headers,
                    data: #"{"project":"\#(project)"}"#
                )
                if !quotaMetrics(provider: .antigravity, payload: payload).isEmpty {
                    return payload
                }
                lastError = AppError("Antigravity 返回空配额")
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppError("Antigravity 配额请求失败")
    }

    private static func apiCall(
        client: ManagementClient,
        authIndex: String,
        method: String,
        url: String,
        headers: [String: String],
        data: String?
    ) async throws -> Any {
        var body: [String: Any] = [
            "authIndex": authIndex,
            "method": method,
            "url": url,
            "header": headers,
        ]
        if let data {
            body["data"] = data
        }
        let response = try await client.sendJSON(method: "POST", path: "api-call", body: body)
        guard let dict = response as? [String: Any] else {
            throw AppError("api-call 响应无效")
        }
        let status = intValue(dict["status_code"] ?? dict["statusCode"]) ?? 0
        if status < 200 || status >= 300 {
            let message = stringValue(dict["error"] ?? dict["message"] ?? dict["body"])
                ?? "上游返回 \(status)"
            throw AppError(message)
        }
        return parseBody(dict["body"] ?? dict["bodyText"])
    }

    private static func loadClaudePlan(authIndex: String, client: ManagementClient) async -> String? {
        do {
            let payload = try await apiCall(
                client: client,
                authIndex: authIndex,
                method: "GET",
                url: "https://api.anthropic.com/api/oauth/profile",
                headers: headers(for: .claude),
                data: nil
            )
            guard let record = asRecord(payload) else { return nil }
            let account = asRecord(record["account"])
            let organization = asRecord(record["organization"])
            if boolValue(account?["has_claude_max"]) == true { return "Max" }
            if boolValue(account?["has_claude_pro"]) == true { return "Pro" }
            if stringValue(organization?["organization_type"])?.lowercased() == "claude_team",
               stringValue(organization?["subscription_status"])?.lowercased() == "active"
            {
                return "Team"
            }
            if boolValue(account?["has_claude_max"]) == false,
               boolValue(account?["has_claude_pro"]) == false
            {
                return "Free"
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func loadAntigravityPlan(authIndex: String, client: ManagementClient) async -> String? {
        do {
            let payload = try await apiCall(
                client: client,
                authIndex: authIndex,
                method: "POST",
                url: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
                headers: headers(for: .antigravity),
                data: #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#
            )
            guard let record = asRecord(payload) else { return nil }
            let current = asRecord(record["currentTier"] ?? record["current_tier"])
            let paid = asRecord(record["paidTier"] ?? record["paid_tier"])
            let tier = (stringValue(paid?["id"]) != nil) ? paid : current
            let tierId = stringValue(tier?["id"])?.lowercased() ?? ""
            let known: [String: String] = [
                "free-tier": "Free",
                "g1-pro-tier": "Pro",
                "g1-ultra-tier": "Ultra",
                "g1-ultra-lite-tier": "Ultra Lite",
            ]
            return known[tierId] ?? stringValue(tier?["name"]) ?? (tierId.isEmpty ? nil : tierId)
        } catch {
            return nil
        }
    }

    // MARK: - Parse metrics

    static func quotaMetrics(provider: QuotaProvider, payload: Any) -> [QuotaMetric] {
        let value = parseBody(payload)
        guard let record = asRecord(value) else { return [] }

        switch provider {
        case .codex:
            return codexMetrics(record)
        case .claude:
            return claudeMetrics(record)
        case .kimi:
            return kimiMetrics(record)
        case .xai:
            return xaiMetrics(record)
        case .antigravity:
            return antigravityMetrics(record)
        case .deepseek:
            return deepSeekMetrics(record)
        }
    }

    private static func deepSeekMetrics(_ value: [String: Any]) -> [QuotaMetric] {
        guard let infos = value["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            return []
        }
        var rows: [QuotaMetric] = []
        for info in infos {
            let currency = stringValue(info["currency"]) ?? "CNY"
            let prefix = infos.count > 1 ? "\(currency) " : ""
            if let total = stringValue(info["total_balance"]) {
                rows.append(QuotaMetric(
                    label: "\(prefix)总余额",
                    remainingPercent: nil,
                    reset: nil,
                    detail: "¥\(total)"
                ))
            }
            if let granted = stringValue(info["granted_balance"]), (Double(granted) ?? 0) > 0 {
                rows.append(QuotaMetric(
                    label: "\(prefix)赠金余额",
                    remainingPercent: nil,
                    reset: nil,
                    detail: "¥\(granted)"
                ))
            }
            if let toppedUp = stringValue(info["topped_up_balance"]), (Double(toppedUp) ?? 0) > 0 {
                rows.append(QuotaMetric(
                    label: "\(prefix)充值余额",
                    remainingPercent: nil,
                    reset: nil,
                    detail: "¥\(toppedUp)"
                ))
            }
        }
        return rows
    }

    private static func codexMetrics(_ value: [String: Any]) -> [QuotaMetric] {
        var windows: [(raw: Any?, kind: String, prefix: String, source: [String: Any])] = []

        func addRateLimit(_ raw: Any?, _ prefix: String) {
            guard let rate = asRecord(raw) else { return }
            windows.append((rate["primary_window"] ?? rate["primaryWindow"], "primary", prefix, rate))
            windows.append((rate["secondary_window"] ?? rate["secondaryWindow"], "secondary", prefix, rate))
        }

        addRateLimit(value["rate_limit"] ?? value["rateLimit"], "")
        addRateLimit(value["code_review_rate_limit"] ?? value["codeReviewRateLimit"], "Code Review ")
        if let additional = value["additional_rate_limits"] as? [[String: Any]]
            ?? value["additionalRateLimits"] as? [[String: Any]]
        {
            for (index, item) in additional.enumerated() {
                let name = stringValue(item["limit_name"] ?? item["limitName"] ?? item["metered_feature"] ?? item["meteredFeature"])
                    ?? "附加 \(index + 1)"
                addRateLimit(item["rate_limit"] ?? item["rateLimit"], "\(name) ")
            }
        }

        let teamPlan = stringValue(value["plan_type"] ?? value["planType"])?.lowercased() == "team"
        return windows.compactMap { item in
            guard let raw = asRecord(item.raw) else { return nil }
            let duration = numberValue(raw["limit_window_seconds"] ?? raw["limitWindowSeconds"])
            let reached = boolValue(item.source["limit_reached"] ?? item.source["limitReached"]) == true
                || boolValue(item.source["allowed"]) == false
            let label = codexWindowLabel(duration: duration, prefix: item.prefix, kind: item.kind, teamPlan: teamPlan)
            let remaining = remainingFromUsedPercent(raw["used_percent"] ?? raw["usedPercent"])
                ?? (reached ? 0 : nil)
            return QuotaMetric(
                label: label,
                remainingPercent: remaining,
                reset: codexResetLabel(raw),
                detail: nil
            )
        }
    }

    private static func claudeMetrics(_ value: [String: Any]) -> [QuotaMetric] {
        let labels: [String: String] = [
            "five_hour": "5 小时",
            "seven_day": "7 天",
            "seven_day_oauth_apps": "7 天 OAuth",
            "seven_day_opus": "7 天 Opus",
            "seven_day_sonnet": "7 天 Sonnet",
            "seven_day_cowork": "7 天 Cowork",
            "iguana_necktie": "Iguana Necktie",
        ]
        var rows: [QuotaMetric] = []
        for (key, label) in labels {
            guard let raw = asRecord(value[key]) else { continue }
            rows.append(QuotaMetric(
                label: label,
                remainingPercent: remainingFromUsedPercent(raw["utilization"]),
                reset: absoluteResetLabel(raw["resets_at"] ?? raw["resetsAt"]),
                detail: nil
            ))
        }
        if let extra = asRecord(value["extra_usage"] ?? value["extraUsage"]),
           boolValue(extra["is_enabled"] ?? extra["isEnabled"]) == true
        {
            let monthlyLimit = numberValue(extra["monthly_limit"] ?? extra["monthlyLimit"])
            let usedCredits = numberValue(extra["used_credits"] ?? extra["usedCredits"])
            let computed: Double? = {
                guard let monthlyLimit, monthlyLimit > 0, let usedCredits else { return nil }
                return ((monthlyLimit - usedCredits) / monthlyLimit) * 100
            }()
            rows.append(QuotaMetric(
                label: "额外用量",
                remainingPercent: remainingFromUsedPercent(extra["utilization"]) ?? clampPercent(computed),
                reset: nil,
                detail: {
                    guard let usedCredits, let monthlyLimit else { return nil }
                    return String(format: "$%.2f / $%.2f", usedCredits / 100, monthlyLimit / 100)
                }()
            ))
        }
        return rows
    }

    private static func kimiMetrics(_ value: [String: Any]) -> [QuotaMetric] {
        var items: [[String: Any]] = []
        if let usage = asRecord(value["usage"]) {
            var copy = usage
            copy["label"] = "每周"
            items.append(copy)
        }
        if let limits = value["limits"] as? [[String: Any]] {
            items.append(contentsOf: limits)
        }
        return items.enumerated().compactMap { index, raw in
            let detail = asRecord(raw["detail"]) ?? raw
            let limit = numberValue(detail["limit"])
            let used = numberValue(detail["used"])
            let remaining = numberValue(detail["remaining"])
            let usedValue = used ?? (limit != nil && remaining != nil ? limit! - remaining! : nil)
            if usedValue == nil && limit == nil { return nil }
            let percent: Double? = {
                guard let limit, limit > 0 else {
                    return (usedValue ?? 0) > 0 ? 0 : nil
                }
                return max(0, limit - (usedValue ?? 0)) / limit * 100
            }()
            let label = stringValue(raw["label"] ?? raw["name"] ?? raw["title"] ?? raw["scope"])
                ?? stringValue(detail["name"] ?? detail["title"] ?? detail["scope"])
                ?? "限额 \(index + 1)"
            return QuotaMetric(
                label: label,
                remainingPercent: clampPercent(percent),
                reset: absoluteResetLabel(detail["reset_at"] ?? detail["resetAt"] ?? detail["reset_time"] ?? detail["resetTime"])
                    ?? relativeResetLabel(detail["reset_in"] ?? detail["resetIn"] ?? detail["ttl"]),
                detail: limit.map { "\(Int(usedValue ?? 0)) / \(Int($0))" }
            )
        }
    }

    private static func xaiPayloads(from value: [String: Any]) -> [[String: Any]] {
        let weekly = asRecord(value["weekly"])
        let monthly = asRecord(value["monthly"])
        if weekly != nil || monthly != nil {
            return [weekly, monthly].compactMap { $0 }
        }
        return [value]
    }

    static func xaiPlan(from payload: Any) -> String? {
        guard let record = asRecord(parseBody(payload)) else { return nil }
        for item in xaiPayloads(from: record) {
            if let tier = stringValue(item["subscriptionTier"] ?? item["subscription_tier"]) {
                return tier
            }
            let config = asRecord(item["config"]) ?? item
            if let tier = stringValue(config["subscriptionTier"] ?? config["subscription_tier"]) {
                return tier
            }
            if boolValue(config["isUnifiedBillingUser"] ?? config["is_unified_billing_user"]) == true {
                return "SuperGrok"
            }
            let periodType = stringValue(asRecord(config["current_period"] ?? config["currentPeriod"])?["type"])?
                .lowercased() ?? ""
            if periodType.contains("week") {
                return "SuperGrok"
            }
        }
        return nil
    }

    private static func xaiMetrics(_ value: [String: Any]) -> [QuotaMetric] {
        var rowsByID: [String: QuotaMetric] = [:]
        for payload in xaiPayloads(from: value) {
            let config = asRecord(payload["config"]) ?? payload
            let currentPeriod = asRecord(config["current_period"] ?? config["currentPeriod"])
            let periodType = stringValue(currentPeriod?["type"])?.lowercased() ?? ""
            let periodReset = absoluteResetLabel(currentPeriod?["end"])
            let weeklyUsed = numberValue(
                config["credit_usage_percent"] ?? config["creditUsagePercent"]
                    ?? config["creditsUsagePercent"] ?? config["creditsUsedPercent"]
                    ?? config["usagePercent"] ?? config["usedPercent"] ?? config["percentUsed"]
            )
            // proto3 / 当前 cli-chat-proxy 在本周已用为 0 时会省略 creditUsagePercent。
            // 有 weekly 周期就按 0% 已用（剩余 100%）处理，不要造一个没有数字的空窗口。
            if weeklyUsed != nil || periodType.contains("week") || currentPeriod != nil {
                rowsByID["weekly"] = QuotaMetric(
                    label: "每周",
                    remainingPercent: remainingFromUsedPercent(weeklyUsed ?? 0),
                    reset: periodReset,
                    detail: nil
                )
            }

            let products = (config["product_usage"] as? [[String: Any]])
                ?? (config["productUsage"] as? [[String: Any]])
                ?? []
            for product in products {
                guard let percent = numberValue(product["usage_percent"] ?? product["usagePercent"]) else { continue }
                let name = stringValue(product["product"]) ?? "产品额度"
                rowsByID["product_\(name)"] = QuotaMetric(
                    label: name,
                    remainingPercent: remainingFromUsedPercent(percent),
                    reset: periodReset,
                    detail: nil
                )
            }

            let limit = numberValue(config["monthly_limit"] ?? config["monthlyLimit"])
            let used = numberValue(config["used"])
            let billingReset = absoluteResetLabel(config["billing_period_end"] ?? config["billingPeriodEnd"])
            if let limit, limit > 0 {
                let usedClamped = min(used ?? 0, limit)
                rowsByID["monthly_included"] = QuotaMetric(
                    label: "每月包含",
                    remainingPercent: clampPercent((limit - usedClamped) / limit * 100),
                    reset: billingReset,
                    detail: String(format: "$%.2f / $%.2f", max(0, limit - usedClamped) / 100, limit / 100)
                )
            } else if let used {
                // SuperGrok unified billing / 按量账户：monthlyLimit 恒为 0，used 是美分。
                rowsByID["monthly_used"] = QuotaMetric(
                    label: "本月已用（按量计费）",
                    remainingPercent: nil,
                    reset: billingReset,
                    detail: String(format: "$%.2f", used / 100)
                )
            }

            let cap = numberValue(config["on_demand_cap"] ?? config["onDemandCap"])
            let onDemandUsed = numberValue(config["on_demand_used"] ?? config["onDemandUsed"])
                ?? (used != nil && limit != nil ? max((used ?? 0) - (limit ?? 0), 0) : nil)
            if let cap, cap > 0 {
                let usedValue = min(onDemandUsed ?? 0, cap)
                rowsByID["on_demand"] = QuotaMetric(
                    label: "按量额度",
                    remainingPercent: clampPercent((cap - usedValue) / cap * 100),
                    reset: billingReset,
                    detail: String(format: "$%.2f / $%.2f", max(0, cap - usedValue) / 100, cap / 100)
                )
            }
        }

        let order = ["weekly", "monthly_included", "on_demand"]
        return order.compactMap { rowsByID[$0] }
            + rowsByID.keys
                .filter { !order.contains($0) }
                .sorted()
                .compactMap { rowsByID[$0] }
    }

    private static func antigravityMetrics(_ value: [String: Any]) -> [QuotaMetric] {
        let groups = value["groups"] as? [[String: Any]] ?? []
        return groups.flatMap { group -> [QuotaMetric] in
            guard let buckets = group["buckets"] as? [[String: Any]] else { return [] }
            let groupLabel = stringValue(group["display_name"] ?? group["displayName"]) ?? "配额"
            let groupDescription = stringValue(group["description"])
            return buckets.enumerated().compactMap { index, bucket in
                let remaining = quotaFraction(bucket["remaining_fraction"] ?? bucket["remainingFraction"])
                guard let remaining else { return nil }
                let bucketLabel = stringValue(bucket["display_name"] ?? bucket["displayName"] ?? bucket["window"])
                let label: String = {
                    if let bucketLabel, buckets.count > 1 || bucketLabel != groupLabel {
                        return "\(groupLabel) · \(bucketLabel)"
                    }
                    return groupLabel.isEmpty ? "配额 \(index + 1)" : groupLabel
                }()
                return QuotaMetric(
                    label: label,
                    remainingPercent: remaining * 100,
                    reset: absoluteResetLabel(bucket["reset_time"] ?? bucket["resetTime"]),
                    detail: stringValue(bucket["description"]) ?? groupDescription
                )
            }
        }
    }

    // MARK: - Provider helpers

    private static func endpoint(for provider: QuotaProvider) -> String {
        switch provider {
        case .claude: return "https://api.anthropic.com/api/oauth/usage"
        case .codex: return "https://chatgpt.com/backend-api/wham/usage"
        case .kimi: return "https://api.kimi.com/coding/v1/usages"
        case .xai: return "https://cli-chat-proxy.grok.com/v1/billing"
        case .antigravity: return "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        case .deepseek: return "https://api.deepseek.com/user/balance"
        }
    }

    private static func headers(for provider: QuotaProvider) -> [String: String] {
        switch provider {
        case .claude:
            return [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
            ]
        case .codex:
            return [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
            ]
        case .kimi:
            return ["Authorization": "Bearer $TOKEN$"]
        case .xai:
            return [
                "Authorization": "Bearer $TOKEN$",
                "x-xai-token-auth": "xai-grok-cli",
                "x-grok-client-version": "1.0.4",
                "x-grok-client-mode": "cli",
                "x-grok-client-identifier": "grok-shell",
                "x-grok-client-surface": "grok-build",
                "accept": "*/*",
                "user-agent": "grok-pager/1.0.4 grok-shell/1.0.4 (macos; aarch64)",
            ]
        case .antigravity:
            return [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)",
            ]
        case .deepseek:
            return [
                "Authorization": "Bearer $TOKEN$",
                "Accept": "application/json",
            ]
        }
    }

    static func providerForFile(_ file: [String: Any]) -> QuotaProvider? {
        let value = (stringValue(file["provider"] ?? file["type"] ?? file["account_type"]) ?? "").lowercased()
        if value == "anthropic" { return .claude }
        if value == "anti-gravity" { return .antigravity }
        return QuotaProvider(rawValue: value)
    }

    // MARK: - Value helpers

    private static func normalizeAuthFiles(_ json: Any) -> [[String: Any]] {
        if let list = json as? [[String: Any]] { return list }
        if let dict = json as? [String: Any] {
            if let list = dict["files"] as? [[String: Any]] { return list }
            if let list = dict["items"] as? [[String: Any]] { return list }
            if let list = dict["data"] as? [[String: Any]] { return list }
        }
        return []
    }

    private static func normalizeProviderList(_ json: Any, sectionKey: String) -> [[String: Any]] {
        if let list = json as? [[String: Any]] { return list }
        if let dict = json as? [String: Any] {
            if let list = dict[sectionKey] as? [[String: Any]] { return list }
            if let list = dict["providers"] as? [[String: Any]] { return list }
            if let list = dict["items"] as? [[String: Any]] { return list }
            if let list = dict["data"] as? [[String: Any]] { return list }
        }
        return []
    }

    private static func fileName(_ file: [String: Any]) -> String {
        stringValue(file["name"] ?? file["file"] ?? file["filename"]) ?? "credential"
    }

    private static func displayName(file: [String: Any], provider: QuotaProvider) -> String {
        let email = stringValue(file["email"] ?? file["account"] ?? file["label"])
        let name = fileName(file)
        if let email, !email.isEmpty {
            return "\(provider.title) · \(email)"
        }
        return "\(provider.title) · \(name)"
    }

    private static func normalizeAuthIndex(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        if let i = value as? Int { return String(i) }
        return ""
    }

    private static func parseBody(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data)
            {
                return json
            }
            return s
        }
        return value
    }

    private static func asRecord(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let record = value as? [String: Any], record["val"] != nil {
            return numberValue(record["val"])
        }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return d
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    private static func clampPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(0, min(100, value))
    }

    private static func remainingFromUsedPercent(_ value: Any?) -> Double? {
        guard let used = clampPercent(numberValue(value)) else { return nil }
        return max(0, min(100, 100 - used))
    }

    private static func quotaFraction(_ value: Any?) -> Double? {
        if let s = value as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%") {
            let num = Double(s.trimmingCharacters(in: .whitespacesAndNewlines).dropLast())
            return num.map { max(0, min(1, $0 / 100)) }
        }
        guard let parsed = numberValue(value) else { return nil }
        return max(0, min(1, parsed))
    }

    private static func absoluteResetLabel(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String, s.isEmpty { return nil }
        let numeric = numberValue(value)
        let date: Date?
        if let numeric {
            let ms = numeric < 1e12 ? numeric * 1000 : numeric
            date = Date(timeIntervalSince1970: ms / 1000)
        } else if let s = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        } else {
            date = nil
        }
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }

    private static func relativeResetLabel(_ value: Any?) -> String? {
        guard let seconds = numberValue(value), seconds > 0 else { return nil }
        let minutes = max(1, Int(ceil(seconds / 60)))
        let days = minutes / 1440
        let hours = minutes / 60
        let remainingHours = (minutes % 1440) / 60
        let remainingMinutes = minutes % 60
        if days > 0 {
            return remainingHours > 0 ? "\(days) 天 \(remainingHours) 小时后" : "\(days) 天后"
        }
        if hours > 0 {
            return remainingMinutes > 0 ? "\(hours) 小时 \(remainingMinutes) 分钟后" : "\(hours) 小时后"
        }
        return "\(minutes) 分钟后"
    }

    private static func codexWindowLabel(duration: Double?, prefix: String, kind: String, teamPlan: Bool) -> String {
        let fiveHour: Double = 18_000
        let week: Double = 604_800
        let minMonth = 28 * 86_400.0
        let maxMonth = 31 * 86_400.0
        if duration == fiveHour { return "\(prefix)5 小时" }
        if duration == week { return "\(prefix)每周" }
        if let duration, duration >= minMonth, duration <= maxMonth {
            return "\(prefix)每月"
        }
        if let duration {
            return "\(prefix)\(formatDuration(duration))"
        }
        if kind == "primary" { return "\(prefix)5 小时" }
        return "\(prefix)\(teamPlan ? "每月" : "每周")"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let day = 86_400.0
        let hour = 3_600.0
        if seconds.truncatingRemainder(dividingBy: day) == 0 {
            return "\(Int(seconds / day)) 天"
        }
        if seconds.truncatingRemainder(dividingBy: hour) == 0 {
            return "\(Int(seconds / hour)) 小时"
        }
        return "\(Int(seconds)) 秒"
    }

    private static func codexResetLabel(_ window: [String: Any]) -> String? {
        absoluteResetLabel(window["reset_at"] ?? window["resetAt"])
            ?? relativeResetLabel(window["reset_after_seconds"] ?? window["resetAfterSeconds"])
    }

    private static func codexResetCredits(from payload: Any) -> Int? {
        guard let value = asRecord(parseBody(payload)) else { return nil }
        let credits = asRecord(value["rate_limit_reset_credits"] ?? value["rateLimitResetCredits"])
        guard let count = numberValue(credits?["available_count"] ?? credits?["availableCount"]) else {
            return nil
        }
        return max(0, Int(count.rounded(.down)))
    }

    private static func codexAccountId(from file: [String: Any]) -> String? {
        stringValue(file["account_id"] ?? file["accountId"] ?? file["chatgpt_account_id"])
            ?? stringValue(asRecord(file["token"])?["account_id"])
            ?? stringValue(asRecord(file["metadata"])?["account_id"])
    }

    private static func xaiUserId(from file: [String: Any]) -> String? {
        let sources: [[String: Any]] = [file, asRecord(file["metadata"]) ?? [:], asRecord(file["attributes"]) ?? [:]]
        for source in sources {
            if let direct = stringValue(source["sub"] ?? source["subject"] ?? source["user_id"] ?? source["userId"]) {
                return direct
            }
            for key in ["oauth", "user"] {
                if let nested = asRecord(source[key]),
                   let value = stringValue(nested["sub"] ?? nested["subject"] ?? nested["user_id"] ?? nested["userId"] ?? nested["id"])
                {
                    return value
                }
            }
        }
        return nil
    }
}

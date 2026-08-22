import CryptoKit
import Foundation
import SQLite3

final class UsageDatabase: @unchecked Sendable {
    static let shared = UsageDatabase()

    private let queue = DispatchQueue(label: "com.maccliproxyapi.usage-db")
    private var db: OpaquePointer?
    private var initializationError: Error?

    /// Refreshed by `buildFilter` right before each query, read by the `cpa_provider_label` SQL
    /// function during that query. Safe without synchronization: all UsageDatabase access is
    /// serialized through `queue`, so no query can interleave with another's refresh.
    private static var sqlNativeResponsesOwners: [String: String] = [:]

    private init() {
        do {
            try open()
            try migrate()
            try seedBuiltinPricesIfNeeded()
        } catch {
            initializationError = error
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    var databaseURL: URL {
        AppPaths.usageDatabaseURL
    }

    func databaseSizeBytes() -> Int64 {
        queue.sync {
            let urls = [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path + "-wal"),
                URL(fileURLWithPath: databaseURL.path + "-shm"),
            ]
            return urls.reduce(0) { total, url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            }
        }
    }

    func exportCSV(to url: URL, query: UsageQuery = UsageQuery()) throws -> Int {
        try queue.sync {
            let filter = Self.buildFilter(query)
            let sql = """
            SELECT timestamp, failed, provider, model, alias, source, endpoint,
                latency_ms, ttft_ms, input_tokens, output_tokens, reasoning_tokens,
                cache_read_tokens, cache_creation_tokens, total_tokens,
                api_key_display, api_key_remark, request_id
            FROM usage_events\(filter.clause)
            ORDER BY timestamp_ms ASC, id ASC
            """
            var lines = [
                "timestamp,failed,provider,model,alias,source,endpoint,latency_ms,ttft_ms,input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_creation_tokens,total_tokens,api_key,api_key_remark,request_id",
            ]
            let rows = try queryRows(sql, binds: filter.binds) { stmt -> String in
                let values = [
                    Self.columnText(stmt, 0),
                    sqlite3_column_int64(stmt, 1) != 0 ? "true" : "false",
                    Self.columnText(stmt, 2),
                    Self.columnText(stmt, 3),
                    Self.columnText(stmt, 4),
                    Self.columnText(stmt, 5),
                    Self.columnText(stmt, 6),
                    String(sqlite3_column_int64(stmt, 7)),
                    sqlite3_column_type(stmt, 8) == SQLITE_NULL ? "" : String(sqlite3_column_int64(stmt, 8)),
                    String(sqlite3_column_int64(stmt, 9)),
                    String(sqlite3_column_int64(stmt, 10)),
                    String(sqlite3_column_int64(stmt, 11)),
                    String(sqlite3_column_int64(stmt, 12)),
                    String(sqlite3_column_int64(stmt, 13)),
                    String(sqlite3_column_int64(stmt, 14)),
                    Self.columnText(stmt, 15),
                    Self.columnText(stmt, 16),
                    Self.columnText(stmt, 17),
                ]
                return values.map(Self.csvEscape).joined(separator: ",")
            }
            lines.append(contentsOf: rows)
            try lines.joined(separator: "\n")
                .appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
            return rows.count
        }
    }

    func deleteRecords(olderThan date: Date?) throws -> Int {
        try queue.sync {
            let db = try readyDatabase()
            let sql: String
            var stmt: OpaquePointer?
            if let date {
                sql = "DELETE FROM usage_events WHERE timestamp_ms < ?;"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw AppError(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSince1970 * 1000))
            } else {
                sql = "DELETE FROM usage_events;"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw AppError(String(cString: sqlite3_errmsg(db)))
                }
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw AppError("清理 usage.db 失败: \(String(cString: sqlite3_errmsg(db)))")
            }
            let deleted = Int(sqlite3_changes(db))
            try execute("PRAGMA wal_checkpoint(TRUNCATE);")
            return deleted
        }
    }

    // MARK: - Open / schema

    private func open() throws {
        try AppPaths.ensureBaseDirectories()
        let path = databaseURL.path
        if sqlite3_open(path, &db) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            throw AppError("打开 usage.db 失败: \(message)")
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA busy_timeout=5000;")
        try registerProviderLabelFunction()
        try AppPaths.secureSensitiveFile(databaseURL)
    }

    /// Expose `UsageProviderLabel.display` to SQL as `cpa_provider_label(...)`.
    ///
    /// Attribution cannot be expressed in SQL: a `codex-api-key` native-Responses GPT leg and a
    /// Codex subscription are both `provider = 'codex'`, and only the credential in `source` tells
    /// them apart. Filtering on the raw column therefore disagreed with the labels shown on the
    /// rows — native-Responses GPT events were listed under 「Codex / OpenAI」 and missing from
    /// 「Codex API Key」. Every query filters through this function so the label a row shows is the
    /// label that selects it.
    private func registerProviderLabelFunction() throws {
        let status = sqlite3_create_function_v2(
            db,
            "cpa_provider_label",
            3,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            { context, argc, argv in
                func text(_ index: Int32) -> String {
                    guard index < argc, let argv, let raw = sqlite3_value_text(argv[Int(index)]) else {
                        return ""
                    }
                    return String(cString: raw)
                }
                let label = UsageProviderLabel.display(
                    text(0),
                    authType: text(1),
                    source: text(2),
                    nativeResponsesOwners: UsageDatabase.sqlNativeResponsesOwners
                )
                sqlite3_result_text(
                    context,
                    label,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            },
            nil,
            nil,
            nil
        )
        guard status == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            throw AppError("注册 usage provider 归属函数失败: \(message)")
        }
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS usage_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_key TEXT NOT NULL UNIQUE,
            timestamp TEXT NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            local_hour TEXT NOT NULL,
            latency_ms INTEGER NOT NULL DEFAULT 0,
            ttft_ms INTEGER,
            source TEXT NOT NULL DEFAULT '',
            auth_index TEXT NOT NULL DEFAULT '',
            failed INTEGER NOT NULL DEFAULT 0,
            provider TEXT NOT NULL DEFAULT '',
            model TEXT NOT NULL DEFAULT '',
            alias TEXT NOT NULL DEFAULT '',
            reasoning_effort TEXT NOT NULL DEFAULT '',
            service_tier TEXT NOT NULL DEFAULT '',
            response_service_tier TEXT NOT NULL DEFAULT '',
            executor_type TEXT NOT NULL DEFAULT '',
            endpoint TEXT NOT NULL DEFAULT '',
            auth_type TEXT NOT NULL DEFAULT '',
            api_key_hash TEXT NOT NULL DEFAULT '',
            api_key_display TEXT NOT NULL DEFAULT '',
            api_key_remark TEXT NOT NULL DEFAULT '',
            request_id TEXT NOT NULL DEFAULT '',
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp ON usage_events(timestamp_ms DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_usage_events_local_hour ON usage_events(local_hour, timestamp_ms DESC);
        CREATE INDEX IF NOT EXISTS idx_usage_events_model_timestamp ON usage_events(model, timestamp_ms DESC);
        CREATE INDEX IF NOT EXISTS idx_usage_events_provider_timestamp ON usage_events(provider, timestamp_ms DESC);
        CREATE INDEX IF NOT EXISTS idx_usage_events_source_timestamp ON usage_events(source, timestamp_ms DESC);
        CREATE TABLE IF NOT EXISTS model_prices (
            model TEXT PRIMARY KEY NOT NULL,
            prompt_per_1m REAL NOT NULL DEFAULT 0,
            completion_per_1m REAL NOT NULL DEFAULT 0,
            cache_per_1m REAL NOT NULL DEFAULT 0,
            cache_read_per_1m REAL NOT NULL DEFAULT 0,
            cache_creation_per_1m REAL NOT NULL DEFAULT 0,
            prompt_configured INTEGER NOT NULL DEFAULT 0,
            completion_configured INTEGER NOT NULL DEFAULT 0,
            cache_read_configured INTEGER NOT NULL DEFAULT 0,
            cache_creation_configured INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT '',
            source_model_id TEXT NOT NULL DEFAULT '',
            updated_at_ms INTEGER NOT NULL DEFAULT 0
        );
        """
        try execute(sql)
    }

    // MARK: - Insert

    @discardableResult
    func insertRecords(_ records: [UsageRecord]) throws -> Int {
        try queue.sync {
            let db = try readyDatabase()
            if records.isEmpty { return 0 }
            try execute("BEGIN IMMEDIATE;")
            var committed = false
            defer {
                if !committed {
                    try? execute("ROLLBACK;")
                }
            }
            let sql = """
            INSERT OR IGNORE INTO usage_events (
                event_key, timestamp, timestamp_ms, local_hour, latency_ms, ttft_ms,
                source, auth_index, failed, provider, model, alias, reasoning_effort,
                service_tier, response_service_tier, executor_type, endpoint, auth_type,
                api_key_hash, api_key_display, api_key_remark, request_id,
                input_tokens, output_tokens, reasoning_tokens, cache_read_tokens,
                cache_creation_tokens, total_tokens, created_at
            ) VALUES (
                ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
            );
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw AppError(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let createdAt = ISO8601DateFormatter().string(from: Date())
            var inserted = 0
            for record in records {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                let tsMs = Self.timestampMillis(record.timestamp)
                let hour = Self.localHour(from: record.timestamp)
                bindText(stmt, 1, record.id)
                bindText(stmt, 2, record.timestamp)
                bindInt(stmt, 3, tsMs)
                bindText(stmt, 4, hour)
                bindInt(stmt, 5, record.latencyMs)
                if let ttft = record.ttftMs {
                    bindInt(stmt, 6, ttft)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                bindText(stmt, 7, record.source)
                bindText(stmt, 8, "")
                bindInt(stmt, 9, record.failed ? 1 : 0)
                bindText(stmt, 10, record.provider)
                bindText(stmt, 11, record.model)
                bindText(stmt, 12, record.alias)
                bindText(stmt, 13, record.reasoningEffort)
                bindText(stmt, 14, "")
                bindText(stmt, 15, "")
                bindText(stmt, 16, "")
                bindText(stmt, 17, record.endpoint)
                bindText(stmt, 18, record.authType)
                bindText(stmt, 19, record.apiKeyHash)
                bindText(stmt, 20, record.apiKeyDisplay)
                bindText(stmt, 21, record.apiKeyRemark)
                bindText(stmt, 22, record.requestId)
                bindInt(stmt, 23, record.tokens.inputTokens)
                bindInt(stmt, 24, record.tokens.outputTokens)
                bindInt(stmt, 25, record.tokens.reasoningTokens)
                bindInt(stmt, 26, record.tokens.cacheReadTokens)
                bindInt(stmt, 27, record.tokens.cacheCreationTokens)
                bindInt(stmt, 28, record.tokens.totalTokens)
                bindText(stmt, 29, createdAt)
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE {
                    inserted += Int(sqlite3_changes(db))
                } else {
                    throw AppError("写入 usage.db 失败: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            try execute("COMMIT;")
            committed = true
            return inserted
        }
    }

    func totalRecords() -> Int {
        queue.sync {
            guard initializationError == nil, db != nil else { return 0 }
            return (try? queryInt("SELECT COUNT(*) FROM usage_events")) ?? 0
        }
    }

    // MARK: - Queries

    func overview(query: UsageQuery) throws -> UsageOverview {
        try queue.sync {
            let filter = Self.buildFilter(query)
            let sql = """
            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN failed = 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN failed != 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(reasoning_tokens), 0),
                COALESCE(SUM(cache_read_tokens), 0),
                COALESCE(SUM(cache_creation_tokens), 0),
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(latency_ms), 0),
                COALESCE(AVG(CASE
                    WHEN output_tokens > 0 AND latency_ms > 0
                    THEN CAST(output_tokens AS REAL) * 1000.0 / latency_ms
                END), 0.0),
                MIN(timestamp_ms),
                MAX(timestamp_ms)
            FROM usage_events\(filter.clause)
            """
            let row = try queryRow(sql, binds: filter.binds) { stmt in
                (
                    Int(sqlite3_column_int64(stmt, 0)),
                    Int(sqlite3_column_int64(stmt, 1)),
                    Int(sqlite3_column_int64(stmt, 2)),
                    Int(sqlite3_column_int64(stmt, 3)),
                    Int(sqlite3_column_int64(stmt, 4)),
                    Int(sqlite3_column_int64(stmt, 5)),
                    Int(sqlite3_column_int64(stmt, 6)),
                    Int(sqlite3_column_int64(stmt, 7)),
                    Int(sqlite3_column_int64(stmt, 8)),
                    Int(sqlite3_column_int64(stmt, 9)),
                    sqlite3_column_double(stmt, 10),
                    sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 11)),
                    sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 12))
                )
            }

            let timelineSQL = """
            SELECT local_hour, COUNT(*),
                COALESCE(SUM(CASE WHEN failed = 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN failed != 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(total_tokens), 0)
            FROM usage_events\(filter.clause)
            GROUP BY local_hour
            ORDER BY local_hour ASC
            """
            let timeline = try queryRows(timelineSQL, binds: filter.binds) { stmt in
                UsageTimelinePoint(
                    hour: Self.columnText(stmt, 0),
                    requests: Int(sqlite3_column_int64(stmt, 1)),
                    success: Int(sqlite3_column_int64(stmt, 2)),
                    failure: Int(sqlite3_column_int64(stmt, 3)),
                    tokens: Int(sqlite3_column_int64(stmt, 4))
                )
            }

            let (cost, priced) = try estimatedCost(filter: filter)

            var overview = UsageOverview(
                totalRequests: row.0,
                successCount: row.1,
                failureCount: row.2,
                inputTokens: row.3,
                outputTokens: row.4,
                reasoningTokens: row.5,
                cacheReadTokens: row.6,
                cacheCreationTokens: row.7,
                totalTokens: row.8,
                tps: row.10,
                estimatedCost: cost,
                pricedRequests: priced,
                timeline: timeline
            )
            if overview.totalRequests > 0 {
                overview.successRate = Double(overview.successCount) * 100.0 / Double(overview.totalRequests)
                overview.averageLatencyMs = Double(row.9) / Double(overview.totalRequests)
                overview.cacheHitRate = UsageProviderLabel.cacheHitPercent(
                    cacheRead: overview.cacheReadTokens,
                    input: overview.inputTokens
                )
                let minutes = Self.windowMinutes(query: query, minMs: row.11, maxMs: row.12)
                overview.rpm = Double(overview.totalRequests) / minutes
                overview.tpm = Double(overview.totalTokens) / minutes
            }
            overview.providers = try providerCategories(query: query)
            return overview
        }
    }

    func analysis(query: UsageQuery) throws -> UsageAnalysis {
        try queue.sync {
            UsageAnalysis(
                models: try categories(column: "model", fallback: "unknown", query: query),
                providers: try providerCategories(query: query),
                sources: try sourceCategories(query: query),
                apiKeys: try apiKeyCategories(query: query)
            )
        }
    }

    /// Attributed provider labels in the current filter window (for the UI filter).
    ///
    /// These double as the filter value, so 「Codex API Key」 selects a provider's chat and
    /// native GPT legs together while 「Codex 订阅」 keeps only the subscription.
    func distinctProviders(query: UsageQuery) throws -> [String] {
        try queue.sync {
            // Ignore provider filter so the list stays complete while filtered.
            var open = query
            open.provider = nil
            let filter = Self.buildFilter(open)
            let sql = """
            SELECT DISTINCT cpa_provider_label(provider, auth_type, source)
            FROM usage_events\(filter.clause)
            ORDER BY 1 COLLATE NOCASE
            """
            return try queryRows(sql, binds: filter.binds) { stmt in
                Self.columnText(stmt, 0)
            }
            .filter { !$0.isEmpty }
        }
    }

    func events(query: UsageQuery) throws -> UsageEventPage {
        try queue.sync {
            let filter = Self.buildFilter(query)
            let total = try queryInt("SELECT COUNT(*) FROM usage_events\(filter.clause)", binds: filter.binds)
            let pageSize = max(20, min(200, query.pageSize))
            let totalPages = max(1, Int(ceil(Double(total) / Double(pageSize))))
            let page = max(1, min(query.page, totalPages))
            let offset = (page - 1) * pageSize

            let sql = """
            SELECT
                event_key, timestamp, latency_ms, ttft_ms, source, failed,
                provider, model, alias, reasoning_effort, endpoint, auth_type,
                api_key_hash, api_key_display, api_key_remark, request_id,
                input_tokens, output_tokens, reasoning_tokens, cache_read_tokens,
                cache_creation_tokens, total_tokens
            FROM usage_events\(filter.clause)
            ORDER BY timestamp_ms DESC, id DESC
            LIMIT ? OFFSET ?
            """
            var binds = filter.binds
            binds.append(.int(pageSize))
            binds.append(.int(offset))
            let items = try queryRows(sql, binds: binds) { stmt -> UsageRecord in
                let ttft: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int64(stmt, 3))
                return UsageRecord(
                    id: Self.columnText(stmt, 0),
                    timestamp: Self.columnText(stmt, 1),
                    latencyMs: Int(sqlite3_column_int64(stmt, 2)),
                    ttftMs: ttft,
                    source: Self.columnText(stmt, 4),
                    failed: sqlite3_column_int64(stmt, 5) != 0,
                    provider: Self.columnText(stmt, 6),
                    model: Self.columnText(stmt, 7),
                    alias: Self.columnText(stmt, 8),
                    reasoningEffort: Self.columnText(stmt, 9),
                    endpoint: Self.columnText(stmt, 10),
                    authType: Self.columnText(stmt, 11),
                    apiKeyHash: Self.columnText(stmt, 12),
                    apiKeyDisplay: Self.columnText(stmt, 13),
                    apiKeyRemark: Self.columnText(stmt, 14),
                    requestId: Self.columnText(stmt, 15),
                    tokens: UsageTokenStats(
                        inputTokens: Int(sqlite3_column_int64(stmt, 16)),
                        outputTokens: Int(sqlite3_column_int64(stmt, 17)),
                        reasoningTokens: Int(sqlite3_column_int64(stmt, 18)),
                        cacheReadTokens: Int(sqlite3_column_int64(stmt, 19)),
                        cacheCreationTokens: Int(sqlite3_column_int64(stmt, 20)),
                        totalTokens: Int(sqlite3_column_int64(stmt, 21))
                    )
                )
            }
            return UsageEventPage(items: items, total: total, page: page, pageSize: pageSize, totalPages: totalPages)
        }
    }

    func pricing(query: UsageQuery) throws -> UsagePricing {
        try queue.sync {
            let filter = Self.buildFilter(query)
            let prices = try loadPrices()
            // Split by attributed provider + model so the same model on Codex 订阅, a Codex API key
            // and a native-Responses GPT leg stay on separate lines — CPA files all three as
            // `codex`, so the credential has to take part in the grouping.
            let sql = """
            SELECT
                COALESCE(NULLIF(TRIM(provider), ''), '未知'),
                TRIM(auth_type),
                TRIM(source),
                COALESCE(NULLIF(TRIM(model), ''), 'unknown'),
                COUNT(*),
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(cache_read_tokens), 0),
                COALESCE(SUM(cache_creation_tokens), 0),
                COALESCE(SUM(total_tokens), 0)
            FROM usage_events\(filter.clause)
            GROUP BY 1, 2, 3, 4
            """
            var merged: [String: UsagePriceRow] = [:]
            var order: [String] = []
            _ = try queryRows(sql, binds: filter.binds) { stmt -> Bool in
                let label = UsageProviderLabel.display(
                    Self.columnText(stmt, 0),
                    authType: Self.columnText(stmt, 1),
                    source: Self.columnText(stmt, 2),
                    nativeResponsesOwners: Self.sqlNativeResponsesOwners
                )
                let model = Self.columnText(stmt, 3)
                // Keyed by label, not the raw column: a provider's multiple legs are one
                // provider to the user, so a model they share must not be split across two lines.
                let id = "\(label)|\(model)"
                var row = merged[id] ?? {
                    order.append(id)
                    return UsagePriceRow(
                        provider: label,
                        providerLabel: label,
                        model: model,
                        requests: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        totalTokens: 0,
                        estimatedCost: 0,
                        price: nil
                    )
                }()
                row.requests += Int(sqlite3_column_int64(stmt, 4))
                row.inputTokens += Int(sqlite3_column_int64(stmt, 5))
                row.outputTokens += Int(sqlite3_column_int64(stmt, 6))
                row.cacheReadTokens += Int(sqlite3_column_int64(stmt, 7))
                row.cacheCreationTokens += Int(sqlite3_column_int64(stmt, 8))
                row.totalTokens += Int(sqlite3_column_int64(stmt, 9))
                merged[id] = row
                return true
            }
            var totalCost = 0.0
            var pricedRequests = 0
            var totalRequests = 0
            // Cost is computed after merging so a split-then-merged group is priced once.
            let rows: [UsagePriceRow] = order.compactMap { merged[$0] }.map { row in
                var row = row
                totalRequests += row.requests
                row.price = Self.matchPrice(model: row.model, prices: prices)
                if let price = row.price {
                    pricedRequests += row.requests
                    let unit = 1_000_000.0
                    row.estimatedCost = Double(row.inputTokens) / unit * price.promptPer1M
                        + Double(row.outputTokens) / unit * price.completionPer1M
                        + Double(row.cacheReadTokens) / unit * price.cacheReadPer1M
                        + Double(row.cacheCreationTokens) / unit * price.cacheCreationPer1M
                    totalCost += row.estimatedCost
                }
                return row
            }
            .sorted { ($0.totalTokens, $0.requests) > ($1.totalTokens, $1.requests) }
            return UsagePricing(
                rows: rows,
                totalCost: totalCost,
                totalRequests: totalRequests,
                pricedRequests: pricedRequests,
                savedPrices: prices.count
            )
        }
    }

    // MARK: - Normalize queue item

    static func normalizeQueueItem(_ item: [String: Any], apiKeys: [GuiApiKey]) -> UsageRecord? {
        let timestamp = string(item["timestamp"]).flatMap { ts -> String? in
            // keep if parseable-ish
            return ts
        } ?? ISO8601DateFormatter().string(from: Date())

        let requestId = string(item["request_id"]) ?? ""
        let apiKey = string(item["api_key"]) ?? ""
        let apiKeyHash = hashText(apiKey)
        let remark = apiKeys.first(where: { $0.apiKey == apiKey })?.remark ?? ""

        let tokensObj = item["tokens"] as? [String: Any]
        let rawCacheRead = intValue(tokensObj?["cache_read_tokens"])
        let cacheCreation = intValue(tokensObj?["cache_creation_tokens"])
        let compatibleCached = max(
            intValue(tokensObj?["cached_tokens"]),
            intValue(tokensObj?["cache_tokens"])
        )
        let extraCached = max(0, compatibleCached - rawCacheRead - cacheCreation)
        var tokens = UsageTokenStats(
            inputTokens: intValue(tokensObj?["input_tokens"]),
            outputTokens: intValue(tokensObj?["output_tokens"]),
            reasoningTokens: intValue(tokensObj?["reasoning_tokens"]),
            cacheReadTokens: rawCacheRead + extraCached,
            cacheCreationTokens: cacheCreation,
            totalTokens: intValue(tokensObj?["total_tokens"])
        )
        if tokens.totalTokens == 0 {
            tokens.totalTokens = tokens.inputTokens + tokens.outputTokens
        }

        let id: String = {
            if !requestId.isEmpty { return requestId }
            // hash of sanitized payload
            var copy = item
            copy.removeValue(forKey: "response_headers")
            copy.removeValue(forKey: "api_key")
            if let data = try? JSONSerialization.data(withJSONObject: copy),
               let text = String(data: data, encoding: .utf8)
            {
                return hashText(text)
            }
            return UUID().uuidString
        }()

        return UsageRecord(
            id: id,
            timestamp: timestamp,
            latencyMs: intValue(item["latency_ms"]),
            ttftMs: {
                let v = intValue(item["ttft_ms"])
                return v > 0 || item["ttft_ms"] != nil ? intValue(item["ttft_ms"]) : nil
            }(),
            source: string(item["source"]) ?? "",
            failed: boolValue(item["failed"]),
            provider: string(item["provider"]) ?? "",
            model: string(item["model"]) ?? "unknown",
            alias: string(item["alias"]) ?? "",
            reasoningEffort: string(item["reasoning_effort"]) ?? "",
            endpoint: string(item["endpoint"]) ?? "",
            authType: string(item["auth_type"]) ?? "",
            apiKeyHash: apiKeyHash,
            apiKeyDisplay: maskAPIKey(apiKey),
            apiKeyRemark: remark,
            requestId: requestId,
            tokens: tokens
        )
    }

    // MARK: - Prices

    /// Upsert bundled `model_prices.json` so new TT Switch / catalog models land on upgrade.
    /// Only overwrites rows with `source = 'builtin'` (or missing); user overrides are preserved.
    private func seedBuiltinPricesIfNeeded() throws {
        guard let url = Bundle.main.url(forResource: "model_prices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: [String: Any]]
        else {
            return
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try execute("BEGIN;")
        var committed = false
        defer {
            if !committed {
                try? execute("ROLLBACK;")
            }
        }
        for (model, price) in models {
            let prompt = Self.doubleValue(price["inputPer1M"])
            let completion = Self.doubleValue(price["outputPer1M"])
            let cacheRead = Self.doubleValue(price["cacheReadPer1M"])
            let cacheCreation = Self.doubleValue(price["cacheCreationPer1M"])
            // Insert if absent; replace only previous builtin rows.
            let sql = """
            INSERT INTO model_prices (
                model, prompt_per_1m, completion_per_1m, cache_per_1m,
                cache_read_per_1m, cache_creation_per_1m,
                prompt_configured, completion_configured, cache_read_configured, cache_creation_configured,
                source, source_model_id, updated_at_ms
            ) VALUES (
                '\(escape(model))', \(prompt), \(completion), 0,
                \(cacheRead), \(cacheCreation),
                1, 1, \(cacheRead > 0 ? 1 : 0), \(cacheCreation > 0 ? 1 : 0),
                'builtin', '\(escape(model))', \(now)
            )
            ON CONFLICT(model) DO UPDATE SET
                prompt_per_1m = excluded.prompt_per_1m,
                completion_per_1m = excluded.completion_per_1m,
                cache_read_per_1m = excluded.cache_read_per_1m,
                cache_creation_per_1m = excluded.cache_creation_per_1m,
                prompt_configured = 1,
                completion_configured = 1,
                cache_read_configured = excluded.cache_read_configured,
                cache_creation_configured = excluded.cache_creation_configured,
                source = 'builtin',
                source_model_id = excluded.source_model_id,
                updated_at_ms = excluded.updated_at_ms
            WHERE model_prices.source = 'builtin' OR model_prices.source = '' OR model_prices.source IS NULL;
            """
            try execute(sql)
        }
        try execute("COMMIT;")
        committed = true
    }

    private func loadPrices() throws -> [ModelPrice] {
        try queryRows("SELECT model, prompt_per_1m, completion_per_1m, cache_read_per_1m, cache_creation_per_1m, source FROM model_prices") { stmt in
            ModelPrice(
                model: Self.columnText(stmt, 0),
                promptPer1M: sqlite3_column_double(stmt, 1),
                completionPer1M: sqlite3_column_double(stmt, 2),
                cacheReadPer1M: sqlite3_column_double(stmt, 3),
                cacheCreationPer1M: sqlite3_column_double(stmt, 4),
                source: Self.columnText(stmt, 5)
            )
        }
    }

    private func estimatedCost(filter: SQLFilter) throws -> (Double, Int) {
        let prices = try loadPrices()
        let sql = """
        SELECT model,
            COUNT(*),
            COALESCE(SUM(input_tokens), 0),
            COALESCE(SUM(output_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0),
            COALESCE(SUM(cache_creation_tokens), 0)
        FROM usage_events\(filter.clause)
        GROUP BY model
        """
        var total = 0.0
        var priced = 0
        _ = try queryRows(sql, binds: filter.binds) { stmt -> Int in
            let model = Self.columnText(stmt, 0)
            let requests = Int(sqlite3_column_int64(stmt, 1))
            let input = Double(sqlite3_column_int64(stmt, 2))
            let output = Double(sqlite3_column_int64(stmt, 3))
            let cacheRead = Double(sqlite3_column_int64(stmt, 4))
            let cacheCreation = Double(sqlite3_column_int64(stmt, 5))
            guard let price = Self.matchPrice(model: model, prices: prices) else { return 0 }
            priced += requests
            let unit = 1_000_000.0
            total += input / unit * price.promptPer1M
                + output / unit * price.completionPer1M
                + cacheRead / unit * price.cacheReadPer1M
                + cacheCreation / unit * price.cacheCreationPer1M
            return requests
        }
        return (total, priced)
    }

    private static func matchPrice(model: String, prices: [ModelPrice]) -> ModelPrice? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = prices.first(where: { $0.model.lowercased() == key }) {
            return exact
        }
        // Normalize Claude-style dots vs dashes: claude-opus-4.8 ↔ claude-opus-4-8
        let dashed = key.replacingOccurrences(of: ".", with: "-")
        if dashed != key, let hit = prices.first(where: { $0.model.lowercased() == dashed }) {
            return hit
        }
        let dotted = key.replacingOccurrences(of: "-", with: ".")
        // Only try dotted if it looks like a versioned id (avoid rewriting gpt-5-mini oddly for contains).
        if dotted != key, key.contains(where: { $0.isNumber }),
           let hit = prices.first(where: { $0.model.lowercased() == dotted })
        {
            return hit
        }
        // Soft match last.
        return prices.first { key.contains($0.model.lowercased()) || $0.model.lowercased().contains(key) }
    }

    /// Provider breakdown attributed by credential, not just by the `provider` column.
    ///
    /// CPA files a native-Responses GPT leg and a Codex subscription under the same `codex`
    /// provider, so grouping on that column alone would report native-Responses traffic as
    /// subscription usage. Rows are grouped by credential and then merged per label, which keeps
    /// several subscription accounts on one line while splitting the native-Responses leg off.
    /// `key` is the label itself, because that is what the provider filter matches on.
    private func providerCategories(query: UsageQuery) throws -> [UsageCategory] {
        let filter = Self.buildFilter(query)
        let sql = """
        SELECT
            COALESCE(NULLIF(TRIM(provider), ''), '未知 Provider'),
            TRIM(auth_type),
            TRIM(source),
            COUNT(*),
            COALESCE(SUM(CASE WHEN failed != 0 THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(input_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0),
            COALESCE(SUM(cache_creation_tokens), 0)
        FROM usage_events\(filter.clause)
        GROUP BY 1, 2, 3
        """
        var merged: [String: UsageCategory] = [:]
        var order: [String] = []
        _ = try queryRows(sql, binds: filter.binds) { stmt -> Bool in
            let label = UsageProviderLabel.display(
                Self.columnText(stmt, 0),
                authType: Self.columnText(stmt, 1),
                source: Self.columnText(stmt, 2),
                nativeResponsesOwners: Self.sqlNativeResponsesOwners
            )
            var entry = merged[label] ?? {
                order.append(label)
                return UsageCategory(key: label, label: label, requests: 0, failures: 0, tokens: 0)
            }()
            entry.requests += Int(sqlite3_column_int64(stmt, 3))
            entry.failures += Int(sqlite3_column_int64(stmt, 4))
            entry.tokens += Int(sqlite3_column_int64(stmt, 5))
            entry.inputTokens += Int(sqlite3_column_int64(stmt, 6))
            entry.cacheReadTokens += Int(sqlite3_column_int64(stmt, 7))
            entry.cacheCreationTokens += Int(sqlite3_column_int64(stmt, 8))
            merged[label] = entry
            return true
        }
        return order.compactMap { merged[$0] }
            .sorted { ($0.tokens, $0.requests) > ($1.tokens, $1.requests) }
    }

    /// 来源 breakdown with credentials masked.
    ///
    /// Under api-key auth `source` is the upstream key itself, so the raw value must not reach the
    /// UI. `key` stays raw so filtering by source keeps working.
    private func sourceCategories(query: UsageQuery) throws -> [UsageCategory] {
        let filter = Self.buildFilter(query)
        let sql = """
        SELECT
            COALESCE(NULLIF(TRIM(source), ''), '未知来源'),
            MAX(CASE WHEN LOWER(TRIM(auth_type)) IN ('apikey', 'api-key', 'api_key') THEN 1 ELSE 0 END),
            COUNT(*),
            COALESCE(SUM(CASE WHEN failed != 0 THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(input_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0),
            COALESCE(SUM(cache_creation_tokens), 0)
        FROM usage_events\(filter.clause)
        GROUP BY 1
        ORDER BY 5 DESC, 3 DESC
        """
        return try queryRows(sql, binds: filter.binds) { stmt in
            let key = Self.columnText(stmt, 0)
            let isCredential = sqlite3_column_int64(stmt, 1) != 0
            return UsageCategory(
                key: key,
                label: UsageProviderLabel.maskSourceIfCredential(
                    key,
                    authType: isCredential ? "apikey" : ""
                ),
                requests: Int(sqlite3_column_int64(stmt, 2)),
                failures: Int(sqlite3_column_int64(stmt, 3)),
                tokens: Int(sqlite3_column_int64(stmt, 4)),
                inputTokens: Int(sqlite3_column_int64(stmt, 5)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 6)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 7))
            )
        }
    }

    /// Plain single-column breakdown. Provider attribution goes through `providerCategories`.
    private func categories(
        column: String,
        fallback: String,
        query: UsageQuery
    ) throws -> [UsageCategory] {
        let allowed = Set(["model", "provider", "source", "alias", "endpoint", "auth_type"])
        guard allowed.contains(column) else {
            throw AppError("usage 非法分类列: \(column)")
        }
        let filter = Self.buildFilter(query)
        let sql = """
        SELECT
            COALESCE(NULLIF(TRIM(\(column)), ''), ?),
            COUNT(*),
            COALESCE(SUM(CASE WHEN failed != 0 THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(input_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0),
            COALESCE(SUM(cache_creation_tokens), 0)
        FROM usage_events\(filter.clause)
        GROUP BY 1
        ORDER BY 4 DESC, 2 DESC
        """
        var binds: [Bind] = [.text(fallback)]
        binds.append(contentsOf: filter.binds)
        return try queryRows(sql, binds: binds) { stmt in
            let key = Self.columnText(stmt, 0)
            return UsageCategory(
                key: key,
                label: key,
                requests: Int(sqlite3_column_int64(stmt, 1)),
                failures: Int(sqlite3_column_int64(stmt, 2)),
                tokens: Int(sqlite3_column_int64(stmt, 3)),
                inputTokens: Int(sqlite3_column_int64(stmt, 4)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 5)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 6))
            )
        }
    }

    private func apiKeyCategories(query: UsageQuery) throws -> [UsageCategory] {
        let filter = Self.buildFilter(query)
        let sql = """
        SELECT
            COALESCE(NULLIF(TRIM(api_key_hash), ''), '未记录密钥'),
            MAX(TRIM(api_key_remark)),
            MAX(TRIM(api_key_display)),
            COUNT(*),
            COALESCE(SUM(CASE WHEN failed != 0 THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(input_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0),
            COALESCE(SUM(cache_creation_tokens), 0)
        FROM usage_events\(filter.clause)
        GROUP BY 1
        ORDER BY 6 DESC, 4 DESC
        """
        return try queryRows(sql, binds: filter.binds) { stmt in
            let key = Self.columnText(stmt, 0)
            let remark = Self.columnText(stmt, 1)
            let display = Self.columnText(stmt, 2)
            let label = remark.isEmpty ? (display.isEmpty ? key : display) : "\(remark) (\(display))"
            return UsageCategory(
                key: key,
                label: label,
                requests: Int(sqlite3_column_int64(stmt, 3)),
                failures: Int(sqlite3_column_int64(stmt, 4)),
                tokens: Int(sqlite3_column_int64(stmt, 5)),
                inputTokens: Int(sqlite3_column_int64(stmt, 6)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 7)),
                cacheCreationTokens: Int(sqlite3_column_int64(stmt, 8))
            )
        }
    }

    // MARK: - SQLite helpers

    private enum Bind {
        case text(String)
        case int(Int)
        case double(Double)
    }

    private struct SQLFilter {
        var clause: String
        var binds: [Bind]
    }

    private static func buildFilter(_ query: UsageQuery) -> SQLFilter {
        sqlNativeResponsesOwners = ProviderSecretStore.nativeResponsesProviderNames()
        var clauses: [String] = []
        var binds: [Bind] = []
        if let start = query.start {
            clauses.append("timestamp_ms >= ?")
            binds.append(.int(Int(start.timeIntervalSince1970 * 1000)))
        }
        if let end = query.end {
            clauses.append("timestamp_ms <= ?")
            binds.append(.int(Int(end.timeIntervalSince1970 * 1000)))
        }
        if let model = query.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            clauses.append("model = ? COLLATE NOCASE")
            binds.append(.text(model))
        }
        if let provider = query.provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            // Attributed label, not the raw column — see `registerProviderLabelFunction`.
            clauses.append("cpa_provider_label(provider, auth_type, source) = ? COLLATE NOCASE")
            binds.append(.text(provider))
        }
        if let source = query.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            clauses.append("source = ? COLLATE NOCASE")
            binds.append(.text(source))
        }
        let clause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return SQLFilter(clause: clause, binds: binds)
    }

    private func execute(_ sql: String) throws {
        let db = try readyDatabase()
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let err { sqlite3_free(err) }
            throw AppError("usage.db 执行失败: \(message)")
        }
    }

    private func readyDatabase() throws -> OpaquePointer {
        if let initializationError {
            throw AppError("usage.db 初始化失败: \(initializationError.localizedDescription)")
        }
        guard let db else { throw AppError("usage.db 未打开") }
        return db
    }

    private func queryInt(_ sql: String, binds: [Bind] = []) throws -> Int {
        try queryRow(sql, binds: binds) { stmt in
            Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func queryRow<T>(_ sql: String, binds: [Bind] = [], map: (OpaquePointer) -> T) throws -> T {
        let rows: [T] = try queryRows(sql, binds: binds, map: map)
        guard let first = rows.first else {
            // For aggregates COUNT always returns a row; still handle empty.
            throw AppError("usage 查询无结果")
        }
        return first
    }

    private func queryRows<T>(_ sql: String, binds: [Bind] = [], map: (OpaquePointer) -> T) throws -> [T] {
        let db = try readyDatabase()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AppError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (index, bind) in binds.enumerated() {
            let i = Int32(index + 1)
            switch bind {
            case .text(let value):
                sqlite3_bind_text(stmt, i, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .int(let value):
                sqlite3_bind_int64(stmt, i, Int64(value))
            case .double(let value):
                sqlite3_bind_double(stmt, i, value)
            }
        }
        var results: [T] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                guard let stmt else { throw AppError("usage 查询状态无效") }
                results.append(map(stmt))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw AppError("usage 查询失败: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        return results
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func timestampMillis(_ timestamp: String) -> Int {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return Int(date.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: timestamp) {
            return Int(date.timeIntervalSince1970 * 1000)
        }
        for format in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = format
            if let date = df.date(from: timestamp) {
                return Int(date.timeIntervalSince1970 * 1000)
            }
        }
        return Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func localHour(from timestamp: String) -> String {
        let ms = timestampMillis(timestamp)
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:00"
        return df.string(from: date)
    }

    private static func windowMinutes(query: UsageQuery, minMs: Int?, maxMs: Int?) -> Double {
        if let start = query.start, let end = query.end {
            return max(1.0 / 60.0, end.timeIntervalSince(start) / 60.0)
        }
        if let minMs, let maxMs, maxMs > minMs {
            return max(1.0 / 60.0, Double(maxMs - minMs) / 60000.0)
        }
        return 1
    }

    private static func hashText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func maskAPIKey(_ key: String) -> String {
        guard key.count > 8 else {
            return key.isEmpty ? "" : String(repeating: "•", count: min(key.count, 6))
        }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        if let d = value as? Double { return Int(d) }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            return ["true", "1", "yes"].contains(s.lowercased())
        }
        return false
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return 0
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

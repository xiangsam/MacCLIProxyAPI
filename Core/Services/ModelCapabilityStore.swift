import Foundation

/// Public reference data only. No inference from model names or local credential metadata.
enum ModelCapabilityStore {
    static let sourceURL = URL(string: "https://models.dev/catalog.json?type=all")!
    static var cacheURL: URL { AppPaths.baseDirectory.appendingPathComponent("model-capabilities.json") }

    private struct SourceCatalog: Decodable {
        var models: [String: SourceModel]
        var providers: [String: SourceProvider]
    }
    private struct SourceProvider: Decodable {
        var name: String?
        var models: [String: SourceModel]
    }
    private struct SourceModel: Decodable {
        var name: String?
        var description: String?
        var reasoning: Bool?
        var reasoning_options: [ModelReasoningOption]?
        var canonical_model_id: String?
        var modalities: Modalities?
        var limit: Limits?
        var tool_call: Bool?
        var structured_output: Bool?
        var last_updated: String?
    }
    private struct Modalities: Decodable {
        var input: [String]?
        var output: [String]?
    }
    private struct Limits: Decodable {
        var context: Int?
        var input: Int?
        var output: Int?
    }

    static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> ModelCapabilitySnapshot {
        let source = try JSONDecoder().decode(SourceCatalog.self, from: data)
        guard !source.models.isEmpty else { throw AppError("models.dev 返回了空模型列表，保留已有缓存") }
        var variants: [String: [ModelCapabilityVariant]] = [:]
        var unmapped = 0
        for (providerID, provider) in source.providers {
            for (modelID, model) in provider.models {
                // Only explicit canonical links: aliases and name similarities are not identity.
                guard let canonicalID = model.canonical_model_id, source.models[canonicalID] != nil else {
                    unmapped += 1
                    continue
                }
                variants[canonicalID, default: []].append(ModelCapabilityVariant(
                    providerID: providerID, providerName: provider.name ?? providerID,
                    providerModelID: modelID, reasoning: model.reasoning,
                    reasoningOptions: model.reasoning_options,
                    inputModalities: model.modalities?.input, outputModalities: model.modalities?.output,
                    contextWindow: model.limit?.context, maxInputTokens: model.limit?.input,
                    maxOutputTokens: model.limit?.output
                ))
            }
        }
        let records = source.models.map { id, model in
            let serving = (variants[id] ?? []).sorted { $0.id < $1.id }
            let levels = Set(serving.flatMap { $0.reasoningOptions ?? [] }
                .filter { $0.type == "effort" }.flatMap { $0.values ?? [] }.compactMap { $0 })
            return ModelCapabilityRecord(
                id: id, name: model.name ?? id, lab: String(id.split(separator: "/").first ?? ""),
                description: model.description, reasoning: model.reasoning,
                reasoningLevels: levels.isEmpty ? nil : levels.sorted(),
                inputModalities: model.modalities?.input, outputModalities: model.modalities?.output,
                contextWindow: model.limit?.context, maxInputTokens: model.limit?.input,
                maxOutputTokens: model.limit?.output, toolCall: model.tool_call,
                structuredOutput: model.structured_output, sourceUpdatedAt: model.last_updated,
                sourceURL: "https://models.dev/models/" + id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "/",
                providerVariants: serving
            )
        }.sorted { $0.id < $1.id }
        return ModelCapabilitySnapshot(source: sourceURL.absoluteString, fetchedAt: fetchedAt,
            unmappedProviderModelCount: unmapped, models: records)
    }

    static func encoded(_ snapshot: ModelCapabilitySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    static func load(from url: URL = cacheURL) throws -> ModelCapabilitySnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ModelCapabilitySnapshot.self, from: Data(contentsOf: url))
        guard snapshot.schemaVersion == 1 else { throw AppError("模型能力缓存版本不受支持，请重新同步") }
        return snapshot
    }

    static func save(_ snapshot: ModelCapabilitySnapshot, to url: URL = cacheURL) throws {
        try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        try encoded(snapshot).write(to: url, options: .atomic)
        try AppPaths.secureSensitiveFile(url)
    }

    static func refresh() async throws -> ModelCapabilitySnapshot {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError("models.dev 下载失败，保留已有缓存")
        }
        guard data.count <= 30_000_000 else { throw AppError("模型目录超过 30 MB，保留已有缓存") }
        return try await Task.detached(priority: .utility) {
            let snapshot = try parse(data)
            try save(snapshot)
            return snapshot
        }.value
    }
}

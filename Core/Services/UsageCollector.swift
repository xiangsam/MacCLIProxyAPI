import Foundation

/// Background collector: polls CLIProxyAPI `GET /v0/management/usage-queue`
/// and persists records into local SQLite (`usage.db`).
///
/// Only the status callbacks touch the main actor. `UsageDatabase` serializes every call on
/// its own queue and blocks the caller, so the poll loop deliberately stays off the main
/// thread — running it there made the app do a synchronous insert plus `COUNT(*)` at 1 Hz.
final class UsageCollector: @unchecked Sendable {
    /// Read and written on the main actor only.
    @MainActor private(set) var status: UsageCollectorStatus = .waiting
    private var task: Task<Void, Never>?
    private let database = UsageDatabase.shared
    private let batchSize = 500

    /// Backoff while the queue keeps coming back empty. An idle kernel is the common case,
    /// and polling it every second only burns wakeups.
    private let idlePollSeconds: UInt64 = 1
    private let maxIdlePollSeconds: UInt64 = 5

    @MainActor var onStatusChange: ((UsageCollectorStatus) -> Void)?
    @MainActor var onRecordsSaved: (() -> Void)?

    @MainActor
    func start(
        isCoreRunning: @escaping @MainActor () -> Bool,
        managementClient: @escaping @MainActor () -> ManagementClient,
        apiKeys: @escaping @MainActor () -> [GuiApiKey]
    ) {
        stop()
        refreshTotal()

        task = Task.detached(priority: .utility) { [weak self] in
            var retrySeconds: UInt64 = 1
            var idleSeconds: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }

                guard await isCoreRunning() else {
                    // No queue to drain, so the stored total cannot change either. The kernel
                    // status itself is only sampled every few seconds, so waking faster than
                    // this would just be a no-op hop to the main actor.
                    await self.updateStatus(state: "waiting-core", message: "等待内核启动")
                    retrySeconds = 1
                    idleSeconds = self.idlePollSeconds
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }

                do {
                    let client = await managementClient()
                    let items = try await self.fetchQueue(client: client)
                    if items.isEmpty {
                        await self.updateStatus(state: "collecting", message: "使用记录采集中")
                        retrySeconds = 1
                        try? await Task.sleep(nanoseconds: idleSeconds * 1_000_000_000)
                        idleSeconds = min(idleSeconds + 1, self.maxIdlePollSeconds)
                        continue
                    }

                    let keys = await apiKeys()
                    let records = items.compactMap { UsageDatabase.normalizeQueueItem($0, apiKeys: keys) }
                    let saved = try self.database.insertRecords(records)
                    let total = self.database.totalRecords()
                    await MainActor.run {
                        var next = self.status
                        next.state = "collecting"
                        next.message = saved > 0 ? "已保存 \(saved) 条新记录" : "使用记录采集中"
                        next.lastCollectedAt = Date()
                        next.totalRecords = total
                        self.apply(next)
                        if saved > 0 {
                            self.onRecordsSaved?()
                        }
                    }
                    retrySeconds = 1
                    idleSeconds = self.idlePollSeconds
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    await self.updateStatus(state: "error", message: error.localizedDescription)
                    try? await Task.sleep(nanoseconds: retrySeconds * 1_000_000_000)
                    retrySeconds = min(retrySeconds * 2, 10)
                }
            }
        }
    }

    @MainActor
    func stop() {
        task?.cancel()
        task = nil
    }

    /// Re-read the row count after something other than the poll loop changed it.
    @MainActor
    func refreshTotal() {
        let database = self.database
        Task.detached(priority: .utility) { [weak self] in
            let total = database.totalRecords()
            await MainActor.run {
                guard let self else { return }
                var next = self.status
                next.totalRecords = total
                self.apply(next)
            }
        }
    }

    private func fetchQueue(client: ManagementClient) async throws -> [[String: Any]] {
        let json = try await client.getJSON(
            path: "usage-queue",
            query: ["count": String(batchSize)]
        )
        if let list = json as? [[String: Any]] {
            return list
        }
        if let list = json as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        if let dict = json as? [String: Any] {
            if let list = dict["items"] as? [[String: Any]] { return list }
            if let list = dict["data"] as? [[String: Any]] { return list }
            if let list = dict["records"] as? [[String: Any]] { return list }
        }
        // Empty object / null → treat as empty queue
        if json is NSNull { return [] }
        return []
    }

    /// Status-only update. The total is left alone: nothing was written, and re-counting here
    /// is what put a `COUNT(*)` on every poll — including while the kernel was stopped.
    @MainActor
    private func updateStatus(state: String, message: String) {
        var next = status
        next.state = state
        next.message = message
        apply(next)
    }

    @MainActor
    private func apply(_ next: UsageCollectorStatus) {
        guard next != status else { return }
        status = next
        onStatusChange?(next)
    }
}

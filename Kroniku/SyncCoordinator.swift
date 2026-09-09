import Foundation

@MainActor
final class SyncCoordinator {
    private let repository: MemoryRepositoryProtocol
    private let syncService: SyncService
    private let defaults: UserDefaults
    private var isSyncing = false
    private static var activeFullSyncTask: Task<Void, Error>?

    private static let cursorKey = "syncCursor"

    init(repository: MemoryRepositoryProtocol, syncService: SyncService = .shared, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.syncService = syncService
        self.defaults = defaults
    }

    func performFullSync() async throws {
        if let activeFullSyncTask = Self.activeFullSyncTask {
            try await activeFullSyncTask.value
            return
        }

        guard !isSyncing else { return }
        isSyncing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performFullSyncOperation()
        }
        Self.activeFullSyncTask = task

        defer {
            isSyncing = false
            Self.activeFullSyncTask = nil
        }

        try await task.value
    }

    private func performFullSyncOperation() async throws {

        do {
            try await pullLatest()
        } catch {
            if error is CancellationError {
                print("Sync pull cancelled by the client task")
            } else {
                print("Sync pull failed: \(error.localizedDescription)")
            }
            throw error
        }
        do {
            try await pushPending()
        } catch {
            if error is CancellationError {
                print("Sync push cancelled by the client task")
            } else {
                print("Sync push failed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    func pushPending() async throws {
        let pending = repository.fetchUnsyncedEvents()
        guard !pending.isEmpty else { return }

        let response = try await syncService.pushSync(events: pending.map(repository.makePushRequest(for:)))
        for applied in response.applied {
            try repository.markSynced(eventId: applied.eventId, version: applied.version, syncedAt: applied.updatedAt)
        }
        for conflict in response.conflicts {
            try repository.applyConflict(eventId: conflict.eventId, serverVersion: conflict.serverVersion, strategy: conflict.strategy)
        }
        for ignored in response.ignored {
            print("Sync ignored event \(ignored.eventId): \(ignored.reason ?? "unspecified")")
        }

    }

    func pullLatest() async throws {
        let response = try await syncService.pullSync(since: defaults.object(forKey: Self.cursorKey) as? Date)
        try repository.mergePulledEvents(response.events)
        if let cursor = response.cursor {
            defaults.set(cursor, forKey: Self.cursorKey)
        }
    }

    func resetCursor() {
        defaults.removeObject(forKey: Self.cursorKey)
    }
}
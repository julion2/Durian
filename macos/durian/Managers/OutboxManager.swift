//
//  OutboxManager.swift
//  Durian
//
//  Tracks outbox state (pending count) for badge display.
//

import Foundation
import Combine

@MainActor
class OutboxManager: ObservableObject {
    static let shared = OutboxManager()

    @Published var pendingCount: Int = 0

    private let backendProvider: () -> (any OutboxBackend)?

    private init() {
        self.backendProvider = { AccountManager.shared.emailBackend }
    }

    /// Test-only initializer for dependency injection
    init(backend: @escaping () -> (any OutboxBackend)?) {
        self.backendProvider = backend
    }

    /// Refresh the pending count from the server.
    func refresh() {
        Task {
            guard let backend = backendProvider() else { return }
            let items = await backend.listOutbox()
            pendingCount = items.count
            Log.debug("OUTBOX", "Pending count: \(pendingCount)")
        }
    }
}

//
//  ErrorManager.swift
//  Durian
//
//  Centralized error display manager
//

import Foundation
import SwiftUI

@MainActor
class ErrorManager: ObservableObject {
    static let shared = ErrorManager()

    @Published var currentError: UserFacingError?

    private var autoDismissTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private let startupTime: Date

    init(startupTime: Date = Date()) {
        self.startupTime = startupTime
    }

    // MARK: - Show / Dismiss

    func show(_ error: UserFacingError) {
        // Drop warnings during startup — transient init chatter (NetworkMonitor, connect)
        let sinceStartup = Date().timeIntervalSince(startupTime)
        if sinceStartup < 4 && error.severity == .warning {
            print("ERROR_MANAGER: Suppressed startup warning: \(error.title)")
            return
        }

        showTask?.cancel()
        autoDismissTask?.cancel()

        showTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.currentError = error

            if error.severity == .warning {
                self.autoDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !Task.isCancelled {
                        self.currentError = nil
                    }
                }
            }
        }
    }

    func dismiss() {
        autoDismissTask?.cancel()
        currentError = nil
    }

    // MARK: - Convenience

    func showWarning(title: String, message: String) {
        show(UserFacingError(title: title, message: message, severity: .warning))
    }

    func showCritical(title: String, message: String, actions: [ErrorAction] = []) {
        show(UserFacingError(title: title, message: message, severity: .critical, actions: actions))
    }
}

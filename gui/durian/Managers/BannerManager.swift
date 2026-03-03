//
//  BannerManager.swift
//  Durian
//
//  Centralized banner display manager
//

import Foundation
import SwiftUI

@MainActor
class BannerManager: ObservableObject {
    static let shared = BannerManager()

    @Published var currentBanner: BannerMessage?

    private var autoDismissTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private let startupTime: Date

    init(startupTime: Date = Date()) {
        self.startupTime = startupTime
    }

    // MARK: - Show / Dismiss

    func show(_ banner: BannerMessage) {
        // Drop non-critical banners during startup — transient init chatter (NetworkMonitor, connect)
        let sinceStartup = Date().timeIntervalSince(startupTime)
        if sinceStartup < 4 && banner.severity != .critical {
            print("BANNER: Suppressed startup banner: \(banner.title)")
            return
        }

        showTask?.cancel()
        autoDismissTask?.cancel()

        showTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.currentBanner = banner

            if banner.severity != .critical {
                self.autoDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !Task.isCancelled {
                        self.currentBanner = nil
                    }
                }
            }
        }
    }

    func dismiss() {
        autoDismissTask?.cancel()
        currentBanner = nil
    }

    // MARK: - Convenience

    func showInfo(title: String, message: String) {
        show(BannerMessage(title: title, message: message, severity: .info))
    }

    func showSuccess(title: String, message: String) {
        show(BannerMessage(title: title, message: message, severity: .success))
    }

    func showWarning(title: String, message: String) {
        show(BannerMessage(title: title, message: message, severity: .warning))
    }

    func showCritical(title: String, message: String, actions: [BannerAction] = []) {
        show(BannerMessage(title: title, message: message, severity: .critical, actions: actions))
    }
}

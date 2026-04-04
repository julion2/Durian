//
//  WindowCloseGuard.swift
//  Durian
//
//  NSViewRepresentable that intercepts window close to allow
//  async save before dismissal.
//

import SwiftUI
import AppKit

struct WindowCloseGuard: NSViewRepresentable {
    @Binding var allowClose: Bool
    let onCloseAttempt: () -> Void

    // MARK: - Coordinator

    class Coordinator: NSObject, NSWindowDelegate {
        var originalDelegate: NSWindowDelegate?
        var allowClose = false
        var onCloseAttempt: (() -> Void)?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowClose { return true }
            onCloseAttempt?()
            return false
        }

        // Forward all other delegate calls to SwiftUI's original delegate
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let d = originalDelegate, d.responds(to: aSelector) { return d }
            return super.forwardingTarget(for: aSelector)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - NSViewRepresentable lifecycle

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.originalDelegate = window.delegate
            context.coordinator.allowClose = self.allowClose
            context.coordinator.onCloseAttempt = self.onCloseAttempt
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.allowClose = self.allowClose
        context.coordinator.onCloseAttempt = self.onCloseAttempt
    }
}

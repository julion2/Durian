//
//  ErrorBannerView.swift
//  Durian
//
//  Banner view for displaying user-facing errors
//

import SwiftUI

struct ErrorBannerView: View {
    let error: UserFacingError
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error.severity.icon)
                .font(.system(size: 16))
                .foregroundStyle(error.severity.color)

            VStack(alignment: .leading, spacing: 4) {
                Text(error.title)
                    .font(.headline)
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !error.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(error.actions) { action in
                        Button(action.label, role: action.role) {
                            action.handler()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
    }
}

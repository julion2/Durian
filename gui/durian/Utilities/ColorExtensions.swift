//
//  ColorExtensions.swift
//  Durian
//
//  Design system colors from Figma + hex initializer
//

import SwiftUI

// MARK: - Hex Initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6: // RGB (e.g. "FF5733")
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0.6; g = 0.4; b = 0.2  // Fallback to brown-ish
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Design System Colors (from Figma)

extension Color {
    enum Detail {
        // Text colors
        static let textPrimary = Color(hex: "0a0a0a")
        static let textSecondary = Color(hex: "4a5565")
        static let textTertiary = Color(hex: "6a7282")
        static let textBody = Color(hex: "101828")
        static let textPlaceholder = Color(hex: "717182")

        // Accent colors
        static let linkBlue = Color(hex: "155dfc")

        // Background colors
        static let cardBackground = Color(hex: "f9fafb")
        static let border = Color(hex: "e5e7eb")
        static let buttonBackground = Color(hex: "f3f3f5")
    }
}

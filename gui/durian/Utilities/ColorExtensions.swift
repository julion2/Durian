//
//  ColorExtensions.swift
//  Durian
//
//  Design system colors from Figma
//  Note: Color.init(hex:) is defined in ProfileManager.swift
//

import SwiftUI

// MARK: - Design System Colors (from Figma)

extension Color {
    enum Detail {
        // Text colors
        static let textPrimary = Color(hex: "0a0a0a")
        static let textSecondary = Color(hex: "4a5565")
        static let textTertiary = Color(hex: "6a7282")
        static let textBody = Color(hex: "101828")
        
        // Accent colors
        static let linkBlue = Color(hex: "155dfc")
        
        // Background colors
        static let cardBackground = Color(hex: "f9fafb")
        static let border = Color(hex: "e5e7eb")
    }
}

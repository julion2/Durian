//
//  AvatarView.swift
//  Durian
//
//  Avatar with initials and hash-based color
//

import SwiftUI

struct AvatarView: View {
    let name: String
    var size: CGFloat = 36
    
    private static let avatarColors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown
    ]
    
    var body: some View {
        ZStack {
            Circle()
                .fill(colorForName)
            
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
    
    /// Extract initials from name (max 2 characters)
    /// "Julian Schenker" → "JS"
    /// "Atlassian Home" → "AH"
    /// "info@example.com" → "I"
    private var initials: String {
        let cleanName = extractDisplayName(from: name)
        let words = cleanName.split(separator: " ")
        
        if words.count >= 2 {
            // First letter of first two words
            let first = words[0].prefix(1).uppercased()
            let second = words[1].prefix(1).uppercased()
            return first + second
        } else if let firstWord = words.first, !firstWord.isEmpty {
            // First 1-2 letters of single word
            return String(firstWord.prefix(2)).uppercased()
        } else {
            return "?"
        }
    }
    
    /// Get consistent color based on name hash
    private var colorForName: Color {
        let cleanName = extractDisplayName(from: name).lowercased()
        var hash = 0
        for char in cleanName.unicodeScalars {
            hash = hash &* 31 &+ Int(char.value)
        }
        let index = abs(hash) % Self.avatarColors.count
        return Self.avatarColors[index]
    }
    
    /// Extract display name from email format
    /// "Julian Schenker <julian@example.com>" → "Julian Schenker"
    /// "julian@example.com" → "julian"
    private func extractDisplayName(from: String) -> String {
        // Check for "Name <email>" format
        if let range = from.range(of: "<") {
            let namePart = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !namePart.isEmpty {
                return namePart
            }
        }
        
        // Check for plain email - use local part
        if from.contains("@") {
            if let atIndex = from.firstIndex(of: "@") {
                return String(from[..<atIndex])
            }
        }
        
        return from
    }
}

#Preview {
    VStack(spacing: 16) {
        HStack(spacing: 12) {
            AvatarView(name: "Julian Schenker")
            AvatarView(name: "Atlassian Home")
            AvatarView(name: "Lime Receipts")
        }
        
        HStack(spacing: 12) {
            AvatarView(name: "HubSpot Billing")
            AvatarView(name: "Lexware")
            AvatarView(name: "incident.io")
        }
        
        HStack(spacing: 12) {
            AvatarView(name: "info@example.com")
            AvatarView(name: "Julian Schenker <julian@test.com>")
            AvatarView(name: "A")
        }
    }
    .padding()
}

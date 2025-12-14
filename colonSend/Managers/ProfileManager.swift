//
//  ProfileManager.swift
//  colonSend
//
//  Manages mail profiles (account groups) loaded from profiles.toml
//

import Foundation
import SwiftUI
import TOMLDecoder

struct Profile: Identifiable, Equatable, Hashable {
    let id = UUID()
    let name: String
    let accounts: [String]  // ["habric", "gmx"] or ["*"] for all
    let isDefault: Bool
    let color: String?  // Hex color string, e.g. "#3B82F6"
    
    var isAll: Bool { accounts.contains("*") }
    
    /// Convert hex color string to SwiftUI Color
    var swiftUIColor: Color {
        guard let hex = color else { return .brown }  // Fallback: Brown
        return Color(hex: hex)
    }
    
    static func == (lhs: Profile, rhs: Profile) -> Bool {
        lhs.name == rhs.name && lhs.accounts == rhs.accounts
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(accounts)
    }
}

struct ProfilesConfig: Decodable {
    let profile: [ProfileEntry]
    
    struct ProfileEntry: Decodable {
        let name: String
        let accounts: [String]
        var `default`: Bool?
        var color: String?  // Hex color, e.g. "#3B82F6"
    }
}

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    
    @Published var profiles: [Profile] = []
    @Published var currentProfile: Profile?
    
    private init() {
        loadProfiles()
    }
    
    func loadProfiles() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/colonSend/profiles.toml")
        
        guard let data = try? Data(contentsOf: configPath),
              let config = try? TOMLDecoder().decode(ProfilesConfig.self, from: data) else {
            print("PROFILES: Failed to load profiles.toml, using default")
            profiles = [Profile(name: "Alle", accounts: ["*"], isDefault: true, color: nil)]
            currentProfile = profiles.first
            return
        }
        
        profiles = config.profile.map { entry in
            Profile(name: entry.name, accounts: entry.accounts, isDefault: entry.default ?? false, color: entry.color)
        }
        
        currentProfile = profiles.first(where: { $0.isDefault }) ?? profiles.first
        print("PROFILES: Loaded \(profiles.count) profiles, current: \(currentProfile?.name ?? "none")")
    }
    
    func buildQuery(tag: String) -> String {
        guard let profile = currentProfile, !profile.isAll else {
            return "tag:\(tag)"
        }
        
        // Build path filter: (path:habric/** OR path:gmx/**)
        // Using path: instead of folder: because notmuch path: matches the directory structure
        let pathFilters = profile.accounts.map { "path:\($0)/**" }
        let pathQuery = pathFilters.joined(separator: " OR ")
        
        let query = "tag:\(tag) AND (\(pathQuery))"
        print("PROFILES: Built query: \(query)")
        return query
    }
}

// MARK: - Color Extension for Hex Support

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

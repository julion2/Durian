//
//  ProfileManager.swift
//  Durian
//
//  Manages mail profiles (account groups) loaded from profiles.toml
//

import Foundation
import SwiftUI
import TOMLDecoder

// MARK: - Folder Config

struct FolderConfig: Hashable {
    let name: String
    let icon: String
    let query: String
}

// MARK: - Profile

struct Profile: Identifiable, Equatable, Hashable {
    let id = UUID()
    let name: String
    let accounts: [String]  // ["habric", "gmx"] or ["*"] for all
    let isDefault: Bool
    let color: String?  // Hex color string, e.g. "#3B82F6"
    let folders: [FolderConfig]  // Folders with custom queries
    
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

// MARK: - TOML Decoding

struct ProfilesConfig: Decodable {
    let profile: [ProfileEntry]
    
    struct ProfileEntry: Decodable {
        let name: String
        let accounts: [String]
        var `default`: Bool?
        var color: String?
        var folders: [FolderEntry]?
    }
    
    struct FolderEntry: Decodable {
        let name: String
        let icon: String
        let query: String
    }
}

// MARK: - Profile Manager

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    
    @Published var profiles: [Profile] = []
    @Published var currentProfile: Profile?
    
    /// Default folders when none are defined in config
    static let defaultFolders: [FolderConfig] = [
        FolderConfig(name: "Inbox", icon: "tray", query: "tag:inbox")
    ]
    
    init() {
        loadProfiles()
    }

    /// Test-only initializer: inject profiles directly, skip file loading
    init(profiles: [Profile], currentProfile: Profile? = nil) {
        self.profiles = profiles
        self.currentProfile = currentProfile ?? profiles.first
    }
    
    func loadProfiles() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/durian/profiles.toml")
        
        guard let data = try? Data(contentsOf: configPath),
              let config = try? TOMLDecoder().decode(ProfilesConfig.self, from: data) else {
            Log.debug("PROFILE", "Failed to load profiles.toml, using default")
            profiles = [Profile(
                name: "All",
                accounts: ["*"],
                isDefault: true,
                color: nil,
                folders: Self.defaultFolders
            )]
            currentProfile = profiles.first
            return
        }
        
        profiles = config.profile.map { entry in
            let folders: [FolderConfig]
            if let entryFolders = entry.folders, !entryFolders.isEmpty {
                folders = entryFolders.map { FolderConfig(name: $0.name, icon: $0.icon, query: $0.query) }
            } else {
                folders = Self.defaultFolders
            }
            
            return Profile(
                name: entry.name,
                accounts: entry.accounts,
                isDefault: entry.default ?? false,
                color: entry.color,
                folders: folders
            )
        }
        
        currentProfile = profiles.first(where: { $0.isDefault }) ?? profiles.first
        Log.info("PROFILE", "Loaded \(profiles.count) profiles, current: \(currentProfile?.name ?? "none")")
        if let profile = currentProfile {
            Log.debug("PROFILE", "Current profile has \(profile.folders.count) folders")
        }
    }
    
    /// Build notmuch query for a folder name
    /// - Looks up query from profile's folder config
    /// - Adds profile path filter for non-"All" profiles
    func buildQuery(folderName: String) -> String {
        guard let profile = currentProfile else {
            return "tag:inbox"
        }
        
        // Find folder query from config
        let baseQuery: String
        if let folder = profile.folders.first(where: { $0.name.lowercased() == folderName.lowercased() }) {
            baseQuery = folder.query
        } else {
            // Fallback: simple tag query
            baseQuery = "tag:\(folderName.lowercased())"
        }
        
        // Add profile path filter (except for "All" profile)
        return buildQueryWithProfileFilter(baseQuery: baseQuery)
    }
    
    /// Add profile path filter to an arbitrary query (e.g. from the search popup)
    func applyProfileFilter(to query: String) -> String {
        return buildQueryWithProfileFilter(baseQuery: query)
    }

    /// Add profile path filter to a base query
    private func buildQueryWithProfileFilter(baseQuery: String) -> String {
        guard let profile = currentProfile, !profile.isAll else {
            return baseQuery
        }
        
        // Build path filter: (path:habric/** OR path:gmx/**)
        let pathFilters = profile.accounts.map { "path:\($0)/**" }
        let pathQuery = pathFilters.joined(separator: " OR ")
        
        let query = "(\(baseQuery)) AND (\(pathQuery))"
        Log.debug("PROFILE", "Built query: \(query)")
        return query
    }
}

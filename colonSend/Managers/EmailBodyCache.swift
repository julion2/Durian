//
//  EmailBodyCache.swift
//  colonSend
//
//  Persistent disk-based cache for email bodies
//  Caches plain text and HTML bodies to avoid re-fetching
//

import Foundation
import AppKit

/// Manages persistent caching of email bodies to disk
/// Uses LRU eviction and tracks cache hits/misses
@MainActor
class EmailBodyCache: ObservableObject {
    static let shared = EmailBodyCache()
    
    private let cacheDirectory: URL
    private var metadata: [UInt32: CachedBodyMetadata] = [:]
    private let maxCacheSize: Int64 = 100_000_000  // 100 MB
    private let maxCacheEntries: Int = 500  // Max 500 emails
    
    // Analytics
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0
    
    struct CachedBodyMetadata: Codable {
        let uid: UInt32
        let accountId: String
        let cachedAt: Date
        var lastAccessDate: Date
        var accessCount: Int
        let bodySize: Int64
        let hasHTML: Bool
        let hasAttributed: Bool
        
        var fileName: String {
            return "\(accountId)_\(uid).json"
        }
    }
    
    struct CachedBody: Codable {
        let uid: UInt32
        let plainBody: String
        let htmlBody: String?
        let attributedBodyData: Data?  // Serialized NSAttributedString
        let cachedAt: Date
    }
    
    private init() {
        // Set up cache directory in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheDirectory = appSupport.appendingPathComponent("colonSend/EmailBodyCache", isDirectory: true)
        
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Load metadata
        loadMetadata()
        
        print("BODY_CACHE: Initialized with \(metadata.count) cached bodies")
        print("BODY_CACHE: Cache directory: \(cacheDirectory.path)")
    }
    
    /// Retrieves cached body for a UID
    func getCachedBody(uid: UInt32, accountId: String) -> (plainBody: String, attributedBody: NSAttributedString?)? {
        guard var meta = metadata[uid], meta.accountId == accountId else {
            cacheMisses += 1
            return nil
        }
        
        let fileURL = cacheDirectory.appendingPathComponent(meta.fileName)
        
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedBody.self, from: data) else {
            // File missing, remove from metadata
            metadata.removeValue(forKey: uid)
            saveMetadata()
            cacheMisses += 1
            return nil
        }
        
        // Update access info
        meta.lastAccessDate = Date()
        meta.accessCount += 1
        metadata[uid] = meta
        saveMetadata()
        
        cacheHits += 1
        
        // Deserialize NSAttributedString if available
        var attributedBody: NSAttributedString?
        if let attrData = cached.attributedBodyData {
            attributedBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: attrData)
        }
        
        print("BODY_CACHE: HIT for UID \(uid) (access count: \(meta.accessCount))")
        
        return (cached.plainBody, attributedBody)
    }
    
    /// Caches email body to disk
    func cacheBody(
        uid: UInt32,
        accountId: String,
        plainBody: String,
        attributedBody: NSAttributedString?
    ) {
        // Serialize NSAttributedString if present
        var attributedBodyData: Data?
        if let attributed = attributedBody {
            attributedBodyData = try? NSKeyedArchiver.archivedData(withRootObject: attributed, requiringSecureCoding: false)
        }
        
        let cached = CachedBody(
            uid: uid,
            plainBody: plainBody,
            htmlBody: nil,  // Could store HTML separately if needed
            attributedBodyData: attributedBodyData,
            cachedAt: Date()
        )
        
        // Encode and save to disk
        guard let data = try? JSONEncoder().encode(cached) else {
            print("BODY_CACHE: ERROR - Failed to encode body for UID \(uid)")
            return
        }
        
        let meta = CachedBodyMetadata(
            uid: uid,
            accountId: accountId,
            cachedAt: Date(),
            lastAccessDate: Date(),
            accessCount: 1,
            bodySize: Int64(data.count),
            hasHTML: attributedBody != nil,
            hasAttributed: attributedBodyData != nil
        )
        
        let fileURL = cacheDirectory.appendingPathComponent(meta.fileName)
        
        do {
            try data.write(to: fileURL)
            metadata[uid] = meta
            saveMetadata()
            
            print("BODY_CACHE: Cached UID \(uid) (\(data.count) bytes)")
            
            // Check if cleanup needed
            Task {
                await cleanupIfNeeded()
            }
        } catch {
            print("BODY_CACHE: ERROR - Failed to write cache file: \(error)")
        }
    }
    
    /// Removes cached body
    func removeCachedBody(uid: UInt32) {
        guard let meta = metadata[uid] else { return }
        
        let fileURL = cacheDirectory.appendingPathComponent(meta.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        metadata.removeValue(forKey: uid)
        saveMetadata()
        
        print("BODY_CACHE: Removed UID \(uid)")
    }
    
    /// Cleans up cache if size or count limits exceeded
    private func cleanupIfNeeded() async {
        let totalSize = metadata.values.reduce(0) { $0 + $1.bodySize }
        let count = metadata.count
        
        guard totalSize > maxCacheSize || count > maxCacheEntries else { return }
        
        print("BODY_CACHE: Cleanup needed (size: \(totalSize), count: \(count))")
        
        // Sort by last access date (oldest first)
        let sorted = metadata.values.sorted { $0.lastAccessDate < $1.lastAccessDate }
        
        let targetSize = maxCacheSize * 80 / 100  // Free to 80%
        let targetCount = maxCacheEntries * 80 / 100
        
        var freedSize: Int64 = 0
        var removedCount = 0
        
        for meta in sorted {
            guard (totalSize - freedSize > targetSize) || (count - removedCount > targetCount) else {
                break
            }
            
            let fileURL = cacheDirectory.appendingPathComponent(meta.fileName)
            try? FileManager.default.removeItem(at: fileURL)
            metadata.removeValue(forKey: meta.uid)
            
            freedSize += meta.bodySize
            removedCount += 1
        }
        
        saveMetadata()
        print("BODY_CACHE: Cleanup complete - removed \(removedCount) entries, freed \(freedSize) bytes")
    }
    
    /// Clears entire cache
    func clearCache() {
        for meta in metadata.values {
            let fileURL = cacheDirectory.appendingPathComponent(meta.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        metadata.removeAll()
        saveMetadata()
        
        cacheHits = 0
        cacheMisses = 0
        
        print("BODY_CACHE: Cache cleared")
    }
    
    /// Returns cache statistics
    func getStats() -> (
        count: Int,
        totalSize: Int64,
        hitRate: Double,
        hits: Int,
        misses: Int
    ) {
        let totalSize = metadata.values.reduce(0) { $0 + $1.bodySize }
        let totalRequests = cacheHits + cacheMisses
        let hitRate = totalRequests > 0 ? Double(cacheHits) / Double(totalRequests) : 0.0
        
        return (
            count: metadata.count,
            totalSize: totalSize,
            hitRate: hitRate,
            hits: cacheHits,
            misses: cacheMisses
        )
    }
    
    // MARK: - Persistence
    
    private var metadataURL: URL {
        cacheDirectory.appendingPathComponent("metadata.json")
    }
    
    private func loadMetadata() {
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([UInt32: CachedBodyMetadata].self, from: data) else {
            return
        }
        
        metadata = decoded
    }
    
    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL)
    }
}

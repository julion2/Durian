//
//  MessageCacheManager.swift
//  colonSend
//
//  Caches parsed MimeMessage objects to avoid re-fetching from IMAP server
//

import Foundation
import ColonMime

/// Manages caching of parsed MimeMessage objects
/// Uses LRU eviction to prevent unbounded memory growth
@MainActor
class MessageCacheManager: ObservableObject {
    static let shared = MessageCacheManager()
    
    private var cache: [UInt32: CachedMessage] = [:]
    private let maxCacheSize: Int = 50  // Keep last 50 messages
    private let maxMemoryUsage: Int64 = 100_000_000  // 100 MB
    
    struct CachedMessage {
        let uid: UInt32
        let message: MimeMessage
        let cachedAt: Date
        let rawData: Data
        var lastAccessDate: Date
        
        var memorySize: Int {
            return rawData.count
        }
    }
    
    private init() {}
    
    /// Retrieves cached message if available
    func getMessage(uid: UInt32) -> MimeMessage? {
        guard var cached = cache[uid] else {
            return nil
        }
        
        // Update access time for LRU
        cached.lastAccessDate = Date()
        cache[uid] = cached
        
        return cached.message
    }
    
    /// Caches a parsed message
    func cacheMessage(_ message: MimeMessage, uid: UInt32, rawData: Data) {
        print("CACHE: Caching message UID \(uid) (\(rawData.count) bytes)")
        
        // Check memory limit before adding
        let currentMemory = cache.values.reduce(0) { $0 + $1.memorySize }
        
        if currentMemory + rawData.count > maxMemoryUsage {
            print("CACHE: Memory limit approaching, evicting old entries")
            evictOldest(count: 10)
        }
        
        cache[uid] = CachedMessage(
            uid: uid,
            message: message,
            cachedAt: Date(),
            rawData: rawData,
            lastAccessDate: Date()
        )
        
        // Check count limit
        if cache.count > maxCacheSize {
            print("CACHE: Size limit reached, evicting LRU entry")
            evictOldest(count: 1)
        }
        
        print("CACHE: Cache now contains \(cache.count) messages")
    }
    
    /// Evicts oldest entries based on last access time
    private func evictOldest(count: Int) {
        let sorted = cache.values.sorted { $0.lastAccessDate < $1.lastAccessDate }
        let toEvict = sorted.prefix(count)
        
        for entry in toEvict {
            cache.removeValue(forKey: entry.uid)
            print("CACHE: Evicted UID \(entry.uid)")
        }
    }
    
    /// Clears entire cache
    func clearCache() {
        print("CACHE: Clearing all cached messages")
        cache.removeAll()
    }
    
    /// Returns cache statistics
    func getCacheStats() -> (count: Int, totalBytes: Int64, hitRate: Double) {
        let totalBytes = cache.values.reduce(0) { $0 + Int64($1.memorySize) }
        return (
            count: cache.count,
            totalBytes: totalBytes,
            hitRate: 0.0  // TODO: Track hits/misses
        )
    }
}

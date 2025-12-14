//
//  EmailBodyCache.swift
//  colonSend
//
//  Persistent SQLite-based cache for email bodies using GRDB
//  Caches plain text and attributed bodies to avoid re-fetching
//

import Foundation
import AppKit
import GRDB

// MARK: - Database Records

/// GRDB Record for cached email bodies
struct CachedBodyRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "cached_bodies"
    
    var id: Int64?
    var uid: Int64  // UInt32 stored as Int64 for SQLite compatibility
    var accountId: String
    var plainBody: String
    var attributedBodyData: Data?
    var cachedAt: Date
    var lastAccessDate: Date
    var accessCount: Int
    var bodySize: Int64
    
    // For conflict resolution on UPSERT
    static let persistenceConflictPolicy = PersistenceConflictPolicy(
        insert: .replace,
        update: .replace
    )
}

/// GRDB Record for cache statistics (singleton)
struct CacheStatsRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "cache_stats"
    
    var id: Int64 = 1
    var cacheHits: Int = 0
    var cacheMisses: Int = 0
    var lastCleanupDate: Date?
}

// MARK: - Old JSON structures for migration

private struct OldCachedBodyMetadata: Codable {
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

private struct OldCachedBody: Codable {
    let uid: UInt32
    let plainBody: String
    let htmlBody: String?
    let attributedBodyData: Data?
    let cachedAt: Date
}

// MARK: - EmailBodyCache

/// Manages persistent caching of email bodies using SQLite/GRDB
/// Uses LRU eviction and tracks cache hits/misses
@MainActor
class EmailBodyCache: ObservableObject {
    static let shared = EmailBodyCache()
    
    private var dbQueue: DatabaseQueue?
    private let dbPath: URL
    private let maxCacheSize: Int64 = 100_000_000  // 100 MB
    private let maxCacheEntries: Int = 500
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("colonSend", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        self.dbPath = cacheDir.appendingPathComponent("email_cache.sqlite")
        
        setupDatabase()
        migrateFromJSON()
    }
    
    // MARK: - Database Setup
    
    private func setupDatabase() {
        do {
            dbQueue = try DatabaseQueue(path: dbPath.path)
            
            var migrator = DatabaseMigrator()
            
            // Version 1: Initial schema
            migrator.registerMigration("v1") { db in
                // Main cache table
                try db.create(table: "cached_bodies", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("uid", .integer).notNull()
                    t.column("accountId", .text).notNull()
                    t.column("plainBody", .text).notNull()
                    t.column("attributedBodyData", .blob)
                    t.column("cachedAt", .datetime).notNull()
                    t.column("lastAccessDate", .datetime).notNull()
                    t.column("accessCount", .integer).notNull().defaults(to: 1)
                    t.column("bodySize", .integer).notNull()
                    
                    t.uniqueKey(["uid", "accountId"])
                }
                
                // Indices for fast queries
                try db.create(index: "idx_account", on: "cached_bodies", columns: ["accountId"], ifNotExists: true)
                try db.create(index: "idx_last_access", on: "cached_bodies", columns: ["lastAccessDate"], ifNotExists: true)
                try db.create(index: "idx_uid_account", on: "cached_bodies", columns: ["uid", "accountId"], ifNotExists: true)
                
                // Statistics table
                try db.create(table: "cache_stats", ifNotExists: true) { t in
                    t.column("id", .integer).primaryKey()
                    t.column("cacheHits", .integer).notNull().defaults(to: 0)
                    t.column("cacheMisses", .integer).notNull().defaults(to: 0)
                    t.column("lastCleanupDate", .datetime)
                }
                
                // Initialize stats row if not exists
                try db.execute(sql: "INSERT OR IGNORE INTO cache_stats (id, cacheHits, cacheMisses) VALUES (1, 0, 0)")
            }
            
            try migrator.migrate(dbQueue!)
            
            let count = try dbQueue!.read { db in
                try CachedBodyRecord.fetchCount(db)
            }
            print("BODY_CACHE_SQLITE: Initialized with \(count) cached bodies")
            print("BODY_CACHE_SQLITE: Database at \(dbPath.path)")
            
        } catch {
            print("BODY_CACHE_SQLITE: ERROR setting up database - \(error)")
        }
    }
    
    // MARK: - Public API
    
    /// Retrieves cached body for a UID
    func getCachedBody(uid: UInt32, accountId: String) -> (plainBody: String, attributedBody: NSAttributedString?)? {
        guard let dbQueue else { return nil }
        
        do {
            return try dbQueue.write { db in
                guard var record = try CachedBodyRecord
                    .filter(Column("uid") == Int64(uid) && Column("accountId") == accountId)
                    .fetchOne(db) else {
                    // Cache miss
                    try updateStats(db: db, hit: false)
                    return nil
                }
                
                // Update access info
                record.lastAccessDate = Date()
                record.accessCount += 1
                try record.update(db)
                
                // Cache hit
                try updateStats(db: db, hit: true)
                
                // Deserialize NSAttributedString if available
                var attributedBody: NSAttributedString?
                if let data = record.attributedBodyData {
                    attributedBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
                }
                
                print("BODY_CACHE_SQLITE: HIT for UID \(uid) (access count: \(record.accessCount))")
                return (record.plainBody, attributedBody)
            }
        } catch {
            print("BODY_CACHE_SQLITE: ERROR getting cached body - \(error)")
            return nil
        }
    }
    
    /// Caches email body
    func cacheBody(
        uid: UInt32,
        accountId: String,
        plainBody: String,
        attributedBody: NSAttributedString?
    ) {
        guard let dbQueue else { return }
        
        // Serialize NSAttributedString if present
        var attributedBodyData: Data?
        if let attributed = attributedBody {
            attributedBodyData = try? NSKeyedArchiver.archivedData(withRootObject: attributed, requiringSecureCoding: false)
        }
        
        let bodySize = Int64(plainBody.utf8.count + (attributedBodyData?.count ?? 0))
        
        do {
            try dbQueue.write { db in
                // Check if record exists
                if var existing = try CachedBodyRecord
                    .filter(Column("uid") == Int64(uid) && Column("accountId") == accountId)
                    .fetchOne(db) {
                    // Update existing
                    existing.plainBody = plainBody
                    existing.attributedBodyData = attributedBodyData
                    existing.lastAccessDate = Date()
                    existing.accessCount += 1
                    existing.bodySize = bodySize
                    try existing.update(db)
                } else {
                    // Insert new
                    let record = CachedBodyRecord(
                        id: nil,
                        uid: Int64(uid),
                        accountId: accountId,
                        plainBody: plainBody,
                        attributedBodyData: attributedBodyData,
                        cachedAt: Date(),
                        lastAccessDate: Date(),
                        accessCount: 1,
                        bodySize: bodySize
                    )
                    try record.insert(db)
                }
            }
            
            print("BODY_CACHE_SQLITE: Cached UID \(uid) (\(bodySize) bytes)")
            
            // Check if cleanup needed (async)
            Task {
                await cleanupIfNeeded()
            }
            
        } catch {
            print("BODY_CACHE_SQLITE: ERROR caching body - \(error)")
        }
    }
    
    /// Removes cached body for a UID
    func removeCachedBody(uid: UInt32, accountId: String? = nil) {
        guard let dbQueue else { return }
        
        do {
            _ = try dbQueue.write { db in
                if let accountId = accountId {
                    try CachedBodyRecord
                        .filter(Column("uid") == Int64(uid) && Column("accountId") == accountId)
                        .deleteAll(db)
                } else {
                    try CachedBodyRecord
                        .filter(Column("uid") == Int64(uid))
                        .deleteAll(db)
                }
            }
            print("BODY_CACHE_SQLITE: Removed UID \(uid)")
        } catch {
            print("BODY_CACHE_SQLITE: ERROR removing cached body - \(error)")
        }
    }
    
    /// Clears entire cache
    func clearCache() {
        guard let dbQueue else { return }
        
        do {
            try dbQueue.write { db in
                try CachedBodyRecord.deleteAll(db)
                
                // Reset stats
                try db.execute(sql: "UPDATE cache_stats SET cacheHits = 0, cacheMisses = 0 WHERE id = 1")
            }
            print("BODY_CACHE_SQLITE: Cache cleared")
        } catch {
            print("BODY_CACHE_SQLITE: ERROR clearing cache - \(error)")
        }
    }
    
    /// Returns cache statistics
    func getStats() -> (
        count: Int,
        totalSize: Int64,
        hitRate: Double,
        hits: Int,
        misses: Int
    ) {
        guard let dbQueue else { return (0, 0, 0, 0, 0) }
        
        do {
            return try dbQueue.read { db in
                let count = try CachedBodyRecord.fetchCount(db)
                let totalSize = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bodySize), 0) FROM cached_bodies") ?? 0
                
                if let stats = try CacheStatsRecord.fetchOne(db, key: 1) {
                    let total = stats.cacheHits + stats.cacheMisses
                    let hitRate = total > 0 ? Double(stats.cacheHits) / Double(total) : 0.0
                    return (count, totalSize, hitRate, stats.cacheHits, stats.cacheMisses)
                }
                return (count, totalSize, 0, 0, 0)
            }
        } catch {
            print("BODY_CACHE_SQLITE: ERROR getting stats - \(error)")
            return (0, 0, 0, 0, 0)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Updates cache statistics
    private func updateStats(db: Database, hit: Bool) throws {
        if hit {
            try db.execute(sql: "UPDATE cache_stats SET cacheHits = cacheHits + 1 WHERE id = 1")
        } else {
            try db.execute(sql: "UPDATE cache_stats SET cacheMisses = cacheMisses + 1 WHERE id = 1")
        }
    }
    
    /// Cleans up cache if size or count limits exceeded (LRU eviction)
    private func cleanupIfNeeded() async {
        guard let dbQueue else { return }
        
        let maxEntries = self.maxCacheEntries
        let maxSize = self.maxCacheSize
        
        do {
            try await dbQueue.write { db in
                let count = try CachedBodyRecord.fetchCount(db)
                let totalSize = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bodySize), 0) FROM cached_bodies") ?? 0
                
                guard count > maxEntries || totalSize > maxSize else { return }
                
                print("BODY_CACHE_SQLITE: Cleanup needed (count: \(count), size: \(totalSize))")
                
                // Calculate how many to delete
                let targetCount = maxEntries * 80 / 100
                let toDelete = max(count - targetCount, 50)
                
                // Delete oldest entries (LRU)
                try db.execute(sql: """
                    DELETE FROM cached_bodies 
                    WHERE id IN (
                        SELECT id FROM cached_bodies 
                        ORDER BY lastAccessDate ASC 
                        LIMIT ?
                    )
                """, arguments: [toDelete])
                
                let deletedCount = db.changesCount
                
                // Update cleanup timestamp
                try db.execute(sql: "UPDATE cache_stats SET lastCleanupDate = ? WHERE id = 1", arguments: [Date()])
                
                print("BODY_CACHE_SQLITE: Cleanup complete - removed \(deletedCount) entries")
            }
        } catch {
            print("BODY_CACHE_SQLITE: ERROR during cleanup - \(error)")
        }
    }
    
    // MARK: - Migration from JSON
    
    /// Migrates existing JSON cache to SQLite (one-time operation)
    private func migrateFromJSON() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldCacheDir = appSupport.appendingPathComponent("colonSend/EmailBodyCache", isDirectory: true)
        let metadataURL = oldCacheDir.appendingPathComponent("metadata.json")
        
        // Check if old cache exists
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }
        
        print("BODY_CACHE_SQLITE: Found old JSON cache, migrating...")
        
        // Read old metadata
        guard let data = try? Data(contentsOf: metadataURL),
              let oldMetadata = try? JSONDecoder().decode([UInt32: OldCachedBodyMetadata].self, from: data) else {
            print("BODY_CACHE_SQLITE: Failed to read old metadata")
            return
        }
        
        var migratedCount = 0
        var failedCount = 0
        
        for (uid, meta) in oldMetadata {
            let fileURL = oldCacheDir.appendingPathComponent(meta.fileName)
            
            guard let bodyData = try? Data(contentsOf: fileURL),
                  let oldBody = try? JSONDecoder().decode(OldCachedBody.self, from: bodyData) else {
                failedCount += 1
                continue
            }
            
            // Deserialize attributed body if exists
            var attributedBody: NSAttributedString?
            if let attrData = oldBody.attributedBodyData {
                attributedBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: attrData)
            }
            
            // Insert into SQLite (using internal method to avoid async issues)
            guard let dbQueue else { continue }
            
            do {
                try dbQueue.write { db in
                    var attributedBodyData: Data?
                    if let attributed = attributedBody {
                        attributedBodyData = try? NSKeyedArchiver.archivedData(withRootObject: attributed, requiringSecureCoding: false)
                    }
                    
                    let record = CachedBodyRecord(
                        id: nil,
                        uid: Int64(uid),
                        accountId: meta.accountId,
                        plainBody: oldBody.plainBody,
                        attributedBodyData: attributedBodyData,
                        cachedAt: meta.cachedAt,
                        lastAccessDate: meta.lastAccessDate,
                        accessCount: meta.accessCount,
                        bodySize: meta.bodySize
                    )
                    try record.insert(db)
                }
                migratedCount += 1
            } catch {
                failedCount += 1
            }
        }
        
        print("BODY_CACHE_SQLITE: Migrated \(migratedCount) entries (\(failedCount) failed)")
        
        // Delete old cache directory
        do {
            try FileManager.default.removeItem(at: oldCacheDir)
            print("BODY_CACHE_SQLITE: Deleted old JSON cache directory")
        } catch {
            print("BODY_CACHE_SQLITE: Failed to delete old cache: \(error)")
        }
    }
}

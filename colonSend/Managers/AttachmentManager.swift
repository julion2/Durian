//
//  AttachmentManager.swift
//  colonSend
//
//  Manager for downloading, caching, and accessing email attachments
//

import Foundation
import AppKit

@MainActor
class AttachmentManager: ObservableObject {
    static let shared = AttachmentManager()
    
    @Published var downloadStates: [UUID: AttachmentDownloadState] = [:]
    @Published var cachedAttachments: [UUID: CachedAttachment] = [:]
    
    private let cacheDirectory: URL
    private let maxCacheSize: Int64 = 500_000_000 // 500 MB
    
    private init() {
        // Set up cache directory in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheDirectory = appSupport.appendingPathComponent("colonSend/AttachmentCache", isDirectory: true)
        
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Load cached attachments metadata
        loadCachedAttachments()
        
        print("ATTACHMENT_MANAGER: Initialized with cache at \(cacheDirectory.path)")
    }
    
    /// Downloads an attachment from IMAP server and caches it locally
    func downloadAttachment(
        _ metadata: IncomingAttachmentMetadata,
        emailUID: UInt32,
        client: IMAPClient
    ) async throws -> URL {
        print("ATTACHMENT_MANAGER: Downloading \(metadata.filename) from UID \(emailUID), section \(metadata.section)")
        
        // Check if already cached
        if let cached = cachedAttachments.values.first(where: { 
            $0.emailUID == emailUID && $0.filename == metadata.filename 
        }) {
            if FileManager.default.fileExists(atPath: cached.localPath.path) {
                print("ATTACHMENT_MANAGER: Using cached file at \(cached.localPath.path)")
                downloadStates[metadata.id] = .downloaded(cachePath: cached.localPath.path)
                updateAccessInfo(for: cached.id)
                return cached.localPath
            } else {
                // Cached file missing, remove from cache
                cachedAttachments.removeValue(forKey: cached.id)
            }
        }
        
        // Set downloading state
        downloadStates[metadata.id] = .downloading(progress: 0.0)
        
        do {
            // Fetch attachment data from IMAP
            let data = try await client.fetchAttachmentData(uid: emailUID, section: metadata.section)
            
            print("ATTACHMENT_MANAGER: Downloaded \(data.count) bytes")
            downloadStates[metadata.id] = .downloading(progress: 0.5)
            
            // Save to cache
            let cacheURL = try saveToCache(data: data, filename: metadata.filename, emailUID: emailUID)
            
            // Create cached attachment record
            let cached = CachedAttachment(
                id: metadata.id,
                filename: metadata.filename,
                localPath: cacheURL,
                sizeBytes: Int64(data.count),
                cachedAt: Date(),
                lastAccessDate: Date(),
                accessCount: 1,
                emailUID: emailUID,
                pinned: false
            )
            
            cachedAttachments[metadata.id] = cached
            saveCachedAttachments()
            
            downloadStates[metadata.id] = .downloaded(cachePath: cacheURL.path)
            
            print("ATTACHMENT_MANAGER: Saved to cache at \(cacheURL.path)")
            
            // Check cache size and cleanup if needed
            Task {
                await cleanupCacheIfNeeded()
            }
            
            return cacheURL
            
        } catch {
            print("ATTACHMENT_MANAGER: ERROR - \(error)")
            downloadStates[metadata.id] = .failed(error: error.localizedDescription)
            throw error
        }
    }
    
    /// Saves attachment data to cache directory
    private func saveToCache(data: Data, filename: String, emailUID: UInt32) throws -> URL {
        // Create unique filename to avoid collisions
        let sanitizedFilename = filename.replacingOccurrences(of: "/", with: "_")
        let uniqueFilename = "\(emailUID)_\(sanitizedFilename)"
        let fileURL = cacheDirectory.appendingPathComponent(uniqueFilename)
        
        try data.write(to: fileURL)
        
        return fileURL
    }
    
    /// Opens attachment with default application
    func openAttachment(_ metadata: IncomingAttachmentMetadata, emailUID: UInt32, client: IMAPClient) async {
        do {
            let url = try await downloadAttachment(metadata, emailUID: emailUID, client: client)
            
            // Open with default app
            NSWorkspace.shared.open(url)
            
        } catch {
            print("ATTACHMENT_MANAGER: Failed to open attachment: \(error)")
        }
    }
    
    /// Shows QuickLook preview for attachment
    func previewAttachment(_ metadata: IncomingAttachmentMetadata, emailUID: UInt32, client: IMAPClient) async throws -> URL {
        let url = try await downloadAttachment(metadata, emailUID: emailUID, client: client)
        return url
    }
    
    /// Saves attachment to user-selected location
    func saveAttachment(_ metadata: IncomingAttachmentMetadata, emailUID: UInt32, client: IMAPClient) async {
        do {
            let cacheURL = try await downloadAttachment(metadata, emailUID: emailUID, client: client)
            
            // Show save panel
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = metadata.filename
            savePanel.message = "Save attachment to..."
            
            if savePanel.runModal() == .OK, let destination = savePanel.url {
                try FileManager.default.copyItem(at: cacheURL, to: destination)
                print("ATTACHMENT_MANAGER: Saved to \(destination.path)")
            }
            
        } catch {
            print("ATTACHMENT_MANAGER: Failed to save attachment: \(error)")
        }
    }
    
    /// Updates access info for cached attachment
    private func updateAccessInfo(for id: UUID) {
        guard var cached = cachedAttachments[id] else { return }
        cached.lastAccessDate = Date()
        cached.accessCount += 1
        cachedAttachments[id] = cached
        saveCachedAttachments()
    }
    
    /// Cleans up cache if it exceeds max size
    private func cleanupCacheIfNeeded() async {
        let totalSize = cachedAttachments.values.reduce(0) { $0 + $1.sizeBytes }
        
        guard totalSize > maxCacheSize else { return }
        
        print("ATTACHMENT_MANAGER: Cache size \(totalSize) exceeds limit \(maxCacheSize), cleaning up...")
        
        // Sort by last access date (oldest first), but keep pinned items
        let sortedAttachments = cachedAttachments.values
            .filter { !$0.pinned }
            .sorted { $0.lastAccessDate < $1.lastAccessDate }
        
        var freedSize: Int64 = 0
        let targetFreeSize = totalSize - (maxCacheSize * 80 / 100) // Free up to 80% of max
        
        for attachment in sortedAttachments {
            guard freedSize < targetFreeSize else { break }
            
            // Delete file
            try? FileManager.default.removeItem(at: attachment.localPath)
            
            // Remove from cache
            cachedAttachments.removeValue(forKey: attachment.id)
            downloadStates.removeValue(forKey: attachment.id)
            
            freedSize += attachment.sizeBytes
            print("ATTACHMENT_MANAGER: Removed \(attachment.filename) from cache")
        }
        
        saveCachedAttachments()
        print("ATTACHMENT_MANAGER: Freed \(freedSize) bytes")
    }
    
    /// Clears entire cache
    func clearCache() {
        for attachment in cachedAttachments.values where !attachment.pinned {
            try? FileManager.default.removeItem(at: attachment.localPath)
        }
        
        cachedAttachments = cachedAttachments.filter { $0.value.pinned }
        downloadStates.removeAll()
        saveCachedAttachments()
        
        print("ATTACHMENT_MANAGER: Cache cleared")
    }
    
    // MARK: - Persistence
    
    private var metadataURL: URL {
        cacheDirectory.appendingPathComponent("cached_attachments.json")
    }
    
    private func loadCachedAttachments() {
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([UUID: CachedAttachment].self, from: data) else {
            return
        }
        
        // Verify files still exist
        var validCache: [UUID: CachedAttachment] = [:]
        for (id, attachment) in decoded {
            if FileManager.default.fileExists(atPath: attachment.localPath.path) {
                validCache[id] = attachment
            }
        }
        
        cachedAttachments = validCache
        print("ATTACHMENT_MANAGER: Loaded \(validCache.count) cached attachments")
    }
    
    private func saveCachedAttachments() {
        guard let data = try? JSONEncoder().encode(cachedAttachments) else { return }
        try? data.write(to: metadataURL)
    }
}

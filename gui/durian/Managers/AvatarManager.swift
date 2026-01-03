//
//  AvatarManager.swift
//  Durian
//
//  Manages avatar loading from Gravatar and Brandfetch with caching
//

import Foundation
import AppKit
import CryptoKit

@MainActor
class AvatarManager: ObservableObject {
    static let shared = AvatarManager()
    
    // Memory Cache
    private var imageCache = NSCache<NSString, NSImage>()
    
    // Failed lookups - don't retry for 24h
    private var failedLookups: [String: Date] = [:]
    
    // Brandfetch token for company logos
    private let brandfetchToken = "1idWonATCJFIseiVHIH"
    
    // Personal domains → Gravatar (company domains → Brandfetch)
    private let personalDomains: Set<String> = [
        // Google
        "gmail.com", "googlemail.com",
        // Microsoft
        "outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.de",
        // Yahoo
        "yahoo.com", "yahoo.de", "ymail.com",
        // German providers
        "gmx.de", "gmx.net", "gmx.at", "gmx.ch",
        "web.de",
        "t-online.de",
        "freenet.de",
        "mail.de", "email.de",
        // Apple
        "icloud.com", "me.com", "mac.com",
        // Other
        "aol.com",
        "protonmail.com", "proton.me", "pm.me",
        "posteo.de", "mailbox.org",
        "tutanota.com", "tutanota.de", "tuta.io"
    ]
    
    private init() {
        imageCache.countLimit = 200
        imageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }
    
    // MARK: - Public API
    
    /// Load avatar for email address
    /// - Parameters:
    ///   - email: Full email string (can be "Name <email>" format)
    ///   - size: Desired image size in pixels
    /// - Returns: NSImage if found, nil otherwise (fallback to initials)
    func loadAvatar(for email: String, size: Int = 128) async -> NSImage? {
        // Extract clean email from "Name <email>" format
        let cleanEmail = extractEmail(from: email).lowercased()
        let cacheKey = cleanEmail as NSString
        
        // Check memory cache
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Check if recently failed (don't retry for 24h)
        if let failedDate = failedLookups[cleanEmail],
           Date().timeIntervalSince(failedDate) < 86400 {
            return nil
        }
        
        // Extract domain
        guard let domain = extractDomain(from: cleanEmail) else {
            return nil
        }
        
        // Try appropriate source based on domain type
        let image: NSImage?
        if personalDomains.contains(domain) {
            // Personal email → try Gravatar
            image = await fetchGravatar(email: cleanEmail, size: size)
        } else {
            // Company email → try Brandfetch
            image = await fetchBrandfetch(domain: domain)
        }
        
        // Cache result
        if let image = image {
            imageCache.setObject(image, forKey: cacheKey)
        } else {
            failedLookups[cleanEmail] = Date()
        }
        
        return image
    }
    
    /// Clear all caches
    func clearCache() {
        imageCache.removeAllObjects()
        failedLookups.removeAll()
    }
    
    // MARK: - Private Methods
    
    /// Extract email address from "Name <email>" format
    private func extractEmail(from string: String) -> String {
        if let start = string.range(of: "<"), let end = string.range(of: ">") {
            return String(string[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return string.trimmingCharacters(in: .whitespaces)
    }
    
    /// Extract domain from email address
    private func extractDomain(from email: String) -> String? {
        guard let atIndex = email.firstIndex(of: "@") else { return nil }
        return String(email[email.index(after: atIndex)...]).lowercased()
    }
    
    /// Fetch avatar from Gravatar
    /// Uses MD5 hash of email, returns 404 if no account exists
    private func fetchGravatar(email: String, size: Int) async -> NSImage? {
        // MD5 hash of lowercase trimmed email
        let hash = Insecure.MD5.hash(data: Data(email.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        
        // d=404 returns 404 if no Gravatar exists (instead of default image)
        let urlString = "https://gravatar.com/avatar/\(hash)?d=404&s=\(size)"
        guard let url = URL(string: urlString) else { return nil }
        
        return await fetchImage(from: url)
    }
    
    /// Fetch company logo from Brandfetch
    /// Requires browser User-Agent to bypass hotlinking protection
    private func fetchBrandfetch(domain: String) async -> NSImage? {
        let urlString = "https://cdn.brandfetch.io/\(domain)?c=\(brandfetchToken)"
        guard let url = URL(string: urlString) else { return nil }
        
        // Browser User-Agent required to bypass hotlinking block
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
        
        return await fetchImage(request: request)
    }
    
    /// Generic image fetcher with error handling (URL version)
    private func fetchImage(from url: URL) async -> NSImage? {
        let request = URLRequest(url: url)
        return await fetchImage(request: request)
    }
    
    /// Generic image fetcher with error handling (Request version)
    private func fetchImage(request: URLRequest) async -> NSImage? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            // Verify we got image data, not HTML error page
            guard let image = NSImage(data: data),
                  image.isValid else {
                return nil
            }
            
            return image
        } catch {
            print("AVATAR Failed to fetch \(request.url?.absoluteString ?? "unknown"): \(error.localizedDescription)")
            return nil
        }
    }
}

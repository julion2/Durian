//
//  SequenceMatcher.swift
//  colonSend
//
//  Pattern matching for key sequences
//

import Foundation

/// Matches key buffer contents against defined sequences
class SequenceMatcher {
    
    // MARK: - Sequence Definitions
    
    /// All defined key sequences
    private let sequences: [SequenceDefinition] = [
        // Single-key navigation
        SequenceDefinition("j", .nextEmail, "Next email"),
        SequenceDefinition("k", .prevEmail, "Previous email"),
        SequenceDefinition("G", .lastEmail, "Last email (Shift+G)"),
        
        // Half-page navigation (Ctrl+d/u)
        SequenceDefinition("ctrl+d", .pageDown, "Half-page down"),
        SequenceDefinition("ctrl+u", .pageUp, "Half-page up"),
        
        // Double-tap sequences
        SequenceDefinition("gg", .firstEmail, "First email"),
        SequenceDefinition("dd", .deleteEmail, "Delete email"),
        SequenceDefinition("zz", .centerView, "Center current email in view"),
        
        // Email actions
        SequenceDefinition("o", .openEmail, "Open email"),
        SequenceDefinition("c", .compose, "Compose new email"),
        SequenceDefinition("r", .reply, "Reply to email"),
        SequenceDefinition("R", .replyAll, "Reply to all"),
        SequenceDefinition("f", .forward, "Forward email"),
        SequenceDefinition("u", .toggleRead, "Toggle read/unread"),
        SequenceDefinition("s", .toggleStar, "Toggle star"),
        
        // View control
        SequenceDefinition("q", .closeDetail, "Close/back"),
        
        // Folder navigation (go-commands)
        SequenceDefinition("gi", .goInbox, "Go to inbox"),
        SequenceDefinition("gs", .goSent, "Go to sent"),
        SequenceDefinition("gd", .goDrafts, "Go to drafts"),
        SequenceDefinition("ga", .goArchive, "Go to archive"),
    ]
    
    /// Prefixes that indicate more keys might follow
    /// These cause partial match when alone
    private let partialPrefixes: Set<String> = ["g", "d", "y", "z"]
    
    // MARK: - Lookup Cache
    
    /// Quick lookup by sequence string
    private lazy var sequenceLookup: [String: KeymapAction] = {
        var lookup: [String: KeymapAction] = [:]
        for seq in sequences {
            lookup[seq.sequence] = seq.action
        }
        return lookup
    }()
    
    /// All possible sequence prefixes for partial matching
    private lazy var allPrefixes: Set<String> = {
        var prefixes = partialPrefixes
        // Add all multi-char sequence prefixes
        for seq in sequences where seq.sequence.count > 1 {
            // Add each prefix of the sequence
            for i in 1..<seq.sequence.count {
                let prefix = String(seq.sequence.prefix(i))
                prefixes.insert(prefix)
            }
        }
        return prefixes
    }()
    
    // MARK: - Public API
    
    /// Match buffer contents against known sequences
    /// - Parameter buffer: Current key buffer contents
    /// - Returns: Match result
    func match(buffer: String) -> SequenceMatchResult {
        // Empty buffer
        if buffer.isEmpty {
            return .noMatch
        }
        
        // Parse count prefix if present
        let (count, sequence) = parseCountAndSequence(buffer)
        
        // If only digits, waiting for action
        if sequence.isEmpty && count != nil {
            return .partial
        }
        
        // Check for exact match
        if let action = sequenceLookup[sequence] {
            let finalCount = count ?? 1
            // Validate count support
            if finalCount > 1 && !action.supportsCount {
                return .match(action: action, count: 1)
            }
            return .match(action: action, count: finalCount)
        }
        
        // Check for partial match (could become a longer sequence)
        if allPrefixes.contains(sequence) {
            return .partial
        }
        
        // Check if sequence with count prefix could match
        if count != nil && allPrefixes.contains(sequence) {
            return .partial
        }
        
        return .noMatch
    }
    
    /// Get description for a sequence
    func description(for sequence: String) -> String? {
        sequences.first { $0.sequence == sequence }?.description
    }
    
    /// Get all sequences for an action
    func sequences(for action: KeymapAction) -> [String] {
        sequences.filter { $0.action == action }.map { $0.sequence }
    }
    
    /// Get all defined sequences (for help display)
    var allSequences: [SequenceDefinition] {
        sequences
    }
    
    // MARK: - Private
    
    /// Parse count prefix from buffer
    /// e.g., "5j" → (5, "j"), "12gg" → (12, "gg"), "gg" → (nil, "gg")
    private func parseCountAndSequence(_ buffer: String) -> (count: Int?, sequence: String) {
        var digits = ""
        var rest = ""
        var foundNonDigit = false
        
        for char in buffer {
            if char.isNumber && !foundNonDigit {
                digits.append(char)
            } else {
                foundNonDigit = true
                rest.append(char)
            }
        }
        
        let count = digits.isEmpty ? nil : Int(digits)
        return (count, rest)
    }
}

// MARK: - Singleton

extension SequenceMatcher {
    static let shared = SequenceMatcher()
}

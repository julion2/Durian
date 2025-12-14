//
//  SequenceMatcher.swift
//  colonSend
//
//  Pattern matching for key sequences - dynamically loaded from keymaps.toml
//

import Foundation

/// Matches key buffer contents against defined sequences
class SequenceMatcher {
    
    // MARK: - Singleton
    
    static let shared = SequenceMatcher()
    
    // MARK: - Dynamic Sequence Storage
    
    /// All defined key sequences (loaded from config)
    private var sequences: [SequenceDefinition] = []
    
    /// Quick lookup by sequence string
    private var sequenceLookup: [String: KeymapAction] = [:]
    
    /// All possible sequence prefixes for partial matching
    private var allPrefixes: Set<String> = []
    
    /// Actions that support count prefix (from config)
    private var countSupportedActions: Set<KeymapAction> = []
    
    // MARK: - Init
    
    private init() {
        reloadFromConfig()
        
        // Observe config changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configDidChange),
            name: .keymapsDidChange,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Config Loading
    
    @objc private func configDidChange() {
        reloadFromConfig()
    }
    
    /// Reload sequences from KeymapsManager config
    func reloadFromConfig() {
        let keymapEntries = KeymapsManager.shared.keymaps.keymaps
        
        // Build sequences from config - entries without modifiers (vim-style keys)
        // Note: Entries WITH modifiers are handled by KeymapHandler.handleLegacyKeymap()
        sequences = keymapEntries
            .filter { $0.enabled && $0.modifiers.isEmpty }
            .compactMap { entry -> SequenceDefinition? in
                guard let action = KeymapAction(rawValue: entry.action) else {
                    print("SEQMATCH: Unknown action '\(entry.action)' - skipping")
                    return nil
                }
                return SequenceDefinition(entry.key, action, entry.description)
            }
        
        // Build count-supported actions set from config
        countSupportedActions = Set(
            keymapEntries
                .filter { $0.supportsCount && $0.enabled }
                .compactMap { KeymapAction(rawValue: $0.action) }
        )
        
        rebuildLookups()
        
        print("SEQMATCH: Loaded \(sequences.count) sequences, \(countSupportedActions.count) with count support")
    }
    
    private func rebuildLookups() {
        // Quick lookup by sequence string
        sequenceLookup = [:]
        for seq in sequences {
            sequenceLookup[seq.sequence] = seq.action
        }
        
        // Build prefixes for partial matching (automatically from multi-char sequences)
        allPrefixes = []
        for seq in sequences where seq.sequence.count > 1 {
            // Add each prefix of the sequence (e.g., "gg" -> "g", "gi" -> "g")
            for i in 1..<seq.sequence.count {
                let prefix = String(seq.sequence.prefix(i))
                allPrefixes.insert(prefix)
            }
        }
        
        print("SEQMATCH: Prefixes for partial matching: \(allPrefixes.sorted())")
    }
    
    // MARK: - Public API
    
    /// Match buffer contents against known sequences
    /// - Parameter buffer: Current key buffer contents
    /// - Returns: Match result
    func match(buffer: String) -> SequenceMatchResult {
        // Empty buffer
        if buffer.isEmpty {
            return .noMatch
        }
        
        // Parse count prefix if present (e.g., "5j" -> count=5, sequence="j")
        let (count, sequence) = parseCountAndSequence(buffer)
        
        // If only digits, waiting for action
        if sequence.isEmpty && count != nil {
            return .partial
        }
        
        // Check for exact match
        if let action = sequenceLookup[sequence] {
            let finalCount = count ?? 1
            // Validate count support from config
            if finalCount > 1 && !countSupportedActions.contains(action) {
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
    
    /// Check if an action supports count prefix
    func supportsCount(_ action: KeymapAction) -> Bool {
        countSupportedActions.contains(action)
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

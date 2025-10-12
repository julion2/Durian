//
//  IMAPTextCleaningUtilities.swift
//  colonSend
//
//  Text cleaning and formatting utilities for IMAP email processing
//

import Foundation
import AppKit

// MARK: - Text Cleaning Extension

extension IMAPClient {
    
    // MARK: Whitespace and Formatting
    
    func cleanWhitespace(_ text: String) -> String {
        var cleaned = text
        
        // Fix line wrapping first
        cleaned = fixLineWrapping(cleaned)
        
        // Remove duplicate content blocks (common in email signatures)
        cleaned = removeDuplicateBlocks(cleaned)
        
        // Remove excessive blank lines (more than 2 consecutive)
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        
        // Remove leading/trailing whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove excessive spaces within lines
        cleaned = cleaned.replacingOccurrences(of: " {3,}", with: "  ", options: .regularExpression)
        
        return cleaned
    }
    
    func fixLineWrapping(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var currentParagraph = ""
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Empty line indicates paragraph break
            if trimmedLine.isEmpty {
                if !currentParagraph.isEmpty {
                    result.append(currentParagraph.trimmingCharacters(in: .whitespaces))
                    currentParagraph = ""
                }
                result.append("")
                continue
            }
            
            // If previous line ended with a letter and current line starts with a letter,
            // it's likely a word that was split across lines
            if !currentParagraph.isEmpty &&
               currentParagraph.last?.isLetter == true &&
               trimmedLine.first?.isLetter == true &&
               !trimmedLine.contains(":") &&  // Avoid joining headers
               trimmedLine.count > 0 {
                // Join with previous line without space if it looks like a split word
                currentParagraph += trimmedLine
            } else {
                // Add space if continuing a paragraph
                if !currentParagraph.isEmpty {
                    currentParagraph += " "
                }
                currentParagraph += trimmedLine
            }
        }
        
        // Add final paragraph
        if !currentParagraph.isEmpty {
            result.append(currentParagraph.trimmingCharacters(in: .whitespaces))
        }
        
        return result.joined(separator: "\n")
    }
    
    // MARK: Duplicate Removal
    
    func removeDuplicateBlocks(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        var uniqueParagraphs: [String] = []
        var seenBlocks: Set<String> = []
        
        for paragraph in paragraphs {
            let cleanParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip very short paragraphs for duplicate detection
            if cleanParagraph.count < 20 {
                uniqueParagraphs.append(paragraph)
                continue
            }
            
            // Check if we've seen this block before (with some tolerance for minor differences)
            let normalizedBlock = cleanParagraph.lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            
            if !seenBlocks.contains(normalizedBlock) {
                seenBlocks.insert(normalizedBlock)
                uniqueParagraphs.append(paragraph)
            }
        }
        
        return uniqueParagraphs.joined(separator: "\n\n")
    }
    
    func removeDuplicateContactBlocks(_ text: String) -> String {
        // Split into paragraphs and look for duplicate contact information
        let paragraphs = text.components(separatedBy: "\n\n")
        var result: [String] = []
        var seenContactInfo: Set<String> = []
        
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if this looks like contact information
            if trimmed.contains("Viktoria Glenz") ||
               (trimmed.contains("Telefon:") && trimmed.contains("E-Mail:")) ||
               (trimmed.contains("Mercedesstr. 3") && trimmed.contains("74366 Kirchheim")) {
                
                // Create a normalized version for comparison
                let normalized = trimmed.lowercased()
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "[^a-zA-Z0-9@. ]", with: "", options: .regularExpression)
                
                // Only keep the first occurrence of this contact block
                if !seenContactInfo.contains(normalized) {
                    seenContactInfo.insert(normalized)
                    result.append(paragraph)
                }
            } else {
                // Keep non-contact paragraphs
                result.append(paragraph)
            }
        }
        
        return result.joined(separator: "\n\n")
    }
    
    // MARK: Signature Removal
    
    func removeEmailSignatureClutter(_ text: String) -> String {
        var cleaned = text
        
        // Remove common email signature patterns
        let signaturePatterns = [
            // Legal disclaimers and confidentiality notices
            "Diese elektronische Nachricht ist vertraulich[\\s\\S]*?durchzuführen\\.",
            "This electronic message is confidential[\\s\\S]*?virus checking\\.",
            
            // Social media links and image placeholders
            "\\[Ein Bild,[^\\]]*\\][^\\n]*",
            "\\[Image:[^\\]]*\\][^\\n]*",
            
            // Office hours in repetitive format
            "Bürozeiten und Telefonzeiten:[\\s\\S]*?per E-Mail jederzeit für dich erreichbar\\.",
            
            // Legal footer links (with or without angle brackets)
            "Impressum[^\\n]*\\|[^\\n]*Datenschutzerklärung[^\\n]*",
            
            // Remove isolated social media hashtags and slogans
            "^#[a-zA-Z]+$",
            "^MENSCHLICH\\. BEWEGEND\\. MEHR\\.$"
        ]
        
        for pattern in signaturePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        
        // Remove duplicate contact information blocks
        cleaned = removeDuplicateContactBlocks(cleaned)
        
        // Clean up any resulting excessive whitespace
        cleaned = cleaned.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
}

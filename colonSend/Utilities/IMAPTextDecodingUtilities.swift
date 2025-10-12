//
//  IMAPTextDecodingUtilities.swift
//  colonSend
//
//  Text encoding/decoding utilities for IMAP email processing
//

import Foundation
import AppKit

// MARK: - Text Decoding Extension

extension IMAPClient {
    
    // MARK: Base64 Decoding
    
    func decodeBase64Content(_ content: String) -> String {
        // Remove whitespace and newlines from base64 content
        let cleanBase64 = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        
        print("📧 Attempting base64 decode on \(cleanBase64.count) characters")
        print("📧 Clean base64 preview: \(String(cleanBase64.prefix(50)))...")
        print("📧 Clean base64 ends with: ...\(String(cleanBase64.suffix(20)))")
        
        guard let decodedData = Data(base64Encoded: cleanBase64) else {
            print("📧 Failed to create Data from base64 string")
            print("📧 Base64 validation failed - might not be valid base64")
            return content  // Return original if decoding fails
        }
        
        print("📧 Successfully created Data object, size: \(decodedData.count) bytes")
        
        guard let decodedString = String(data: decodedData, encoding: .utf8) else {
            print("📧 Failed to create UTF-8 string from base64 data, trying Latin1")
            // Try Latin1 encoding for older emails
            if let latin1String = String(data: decodedData, encoding: .isoLatin1) {
                print("📧 Successfully decoded base64 content as Latin1")
                print("📧 Latin1 decode preview: \(String(latin1String.prefix(200)))")
                return latin1String
            }
            print("📧 Failed to decode base64 content with any encoding")
            return content
        }
        
        print("📧 Successfully decoded base64 content as UTF-8")
        print("📧 UTF-8 decode preview: \(String(decodedString.prefix(200)))")
        return decodedString
    }
    
    func isBase64Content(_ content: String) -> Bool {
        // Remove all whitespace for analysis
        let cleaned = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        
        print("📧 Base64 detection input: '\(String(content.prefix(100)))...'")
        print("📧 Base64 detection cleaned: '\(String(cleaned.prefix(100)))...'")
        
        // Must be reasonably long and contain mostly base64 characters
        guard cleaned.count > 50 else {
            print("📧 Base64 detection: Too short (\(cleaned.count) chars)")
            return false
        }
        
        // Count base64 characters
        let base64CharSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let base64Chars = cleaned.unicodeScalars.filter { base64CharSet.contains($0) }.count
        let ratio = Double(base64Chars) / Double(cleaned.count)
        
        print("📧 Base64 detection: \(base64Chars)/\(cleaned.count) chars = \(String(format: "%.1f", ratio*100))% base64")
        
        // Also check if it looks like typical base64 email content (starts with common patterns)
        let startsWithHTMLBase64 = cleaned.hasPrefix("PGh0bWw") || cleaned.hasPrefix("PCEtLQ") // <html or <!--
        let startsWithCommonBase64 = cleaned.hasPrefix("TWltZS") || cleaned.hasPrefix("Q29udGV") // MIME- or Conte
        
        print("📧 Base64 patterns: startsWithHTML=\(startsWithHTMLBase64), startsWithCommon=\(startsWithCommonBase64)")
        
        // If more than 85% of characters are valid base64, OR it has typical base64 patterns, consider it base64 content
        let isBase64 = ratio > 0.85 || startsWithHTMLBase64 || startsWithCommonBase64
        print("📧 Is base64 content: \(isBase64) (ratio=\(String(format: "%.1f", ratio*100))%)")
        return isBase64
    }
    
    // MARK: Quoted-Printable Decoding
    
    func decodeQuotedPrintable(_ text: String) -> String {
        var decoded = text
        
        // Replace quoted-printable sequences
        let quotedPrintablePattern = "=([0-9A-Fa-f]{2})"
        let regex = try? NSRegularExpression(pattern: quotedPrintablePattern)
        
        while let match = regex?.firstMatch(in: decoded, range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)) {
            let hexString = String(decoded[Range(match.range(at: 1), in: decoded)!])
            if let hexValue = UInt8(hexString, radix: 16),
               let unicodeScalar = UnicodeScalar(UInt32(hexValue)) {
                let character = String(Character(unicodeScalar))
                decoded = decoded.replacingCharacters(in: Range(match.range, in: decoded)!, with: character)
            } else {
                break
            }
        }
        
        // Replace soft line breaks (=\n)
        decoded = decoded.replacingOccurrences(of: "=\n", with: "")
        decoded = decoded.replacingOccurrences(of: "=\r\n", with: "")
        
        return decoded
    }
    
    // MARK: RFC 2047 Decoding
    
    func decodeRFC2047(_ text: String) -> String {
        // RFC 2047 encoded-word format: =?charset?encoding?encoded-text?=
        // Example: =?UTF-8?B?SGVsbG8gV29ybGQ=?= (Base64)
        // Example: =?UTF-8?Q?Hello=20World?= (Quoted-Printable)
        
        var result = text
        let pattern = "=\\?([^?]+)\\?([BQbq])\\?([^?]+)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        
        // Process all encoded words in the text
        while let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.count)) {
            guard match.numberOfRanges >= 4 else { break }
            
            let fullMatch = String(result[Range(match.range(at: 0), in: result)!])
            let charset = String(result[Range(match.range(at: 1), in: result)!]).uppercased()
            let encoding = String(result[Range(match.range(at: 2), in: result)!]).uppercased()
            let encodedText = String(result[Range(match.range(at: 3), in: result)!])
            
            var decodedText = ""
            
            switch encoding {
            case "B": // Base64
                if let data = Data(base64Encoded: encodedText) {
                    if let decoded = String(data: data, encoding: .utf8) {
                        decodedText = decoded
                    } else if charset == "ISO-8859-1" || charset == "LATIN1" {
                        // Try Latin1 encoding for older emails
                        decodedText = String(data: data, encoding: .isoLatin1) ?? encodedText
                    }
                }
                
            case "Q": // Quoted-Printable
                // RFC 2047 quoted-printable is slightly different from regular quoted-printable
                // Underscores represent spaces, and regular QP encoding for other characters
                var qpText = encodedText.replacingOccurrences(of: "_", with: " ")
                decodedText = decodeQuotedPrintable(qpText)
                
            default:
                decodedText = encodedText // Unknown encoding, use as-is
            }
            
            // Replace the encoded word with decoded text
            result = result.replacingOccurrences(of: fullMatch, with: decodedText)
        }
        
        return result
    }
    
    // MARK: Modified UTF-7 Decoding (for IMAP folder names)
    
    func decodeModifiedUTF7(_ text: String) -> String {
        // Modified UTF-7 decoding for IMAP folder names
        // Pattern: &XXX- where XXX is base64-encoded UTF-16
        
        var result = text
        let pattern = "&([A-Za-z0-9+/]*)-"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        
        print("📁 MUTF7: Decoding '\(text)'")
        
        // Process all encoded sequences
        while let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: result.count)) {
            guard match.numberOfRanges >= 2 else { break }
            
            let fullMatch = String(result[Range(match.range(at: 0), in: result)!])
            let base64Part = String(result[Range(match.range(at: 1), in: result)!])
            
            var decodedText = ""
            
            if base64Part.isEmpty {
                // &- represents &
                decodedText = "&"
            } else {
                // Decode base64 to UTF-16, then convert to string
                // Add padding if needed
                var paddedBase64 = base64Part
                while paddedBase64.count % 4 != 0 {
                    paddedBase64 += "="
                }
                
                if let data = Data(base64Encoded: paddedBase64) {
                    // Convert UTF-16BE data to string
                    if let decoded = String(data: data, encoding: .utf16BigEndian) {
                        decodedText = decoded
                    } else if let decoded = String(data: data, encoding: .utf16LittleEndian) {
                        decodedText = decoded
                    } else {
                        // Fallback: manual decode common patterns
                        decodedText = decodeCommonModifiedUTF7Patterns(base64Part)
                    }
                }
            }
            
            print("📁 MUTF7: '\(fullMatch)' -> '\(decodedText)'")
            result = result.replacingOccurrences(of: fullMatch, with: decodedText)
        }
        
        print("📁 MUTF7: Final result: '\(result)'")
        return result
    }
    
    func decodeCommonModifiedUTF7Patterns(_ base64: String) -> String {
        // Common Modified UTF-7 patterns for German characters
        let commonPatterns = [
            "APY": "ö",  // &APY- = ö
            "APQ": "ä",  // &APQ- = ä
            "APw": "ü",  // &APw- = ü
            "AOU": "Ä",  // &AOU- = Ä
            "AOY": "Ö",  // &AOY- = Ö
            "AOw": "Ü",  // &AOw- = Ü
            "AN8": "ß"   // &AN8- = ß
        ]
        
        return commonPatterns[base64] ?? base64
    }
}

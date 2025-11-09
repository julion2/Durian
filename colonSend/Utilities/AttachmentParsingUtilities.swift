//
//  AttachmentParsingUtilities.swift
//  colonSend
//
//  BODYSTRUCTURE parsing utilities for attachment detection
//

import Foundation

extension IMAPClient {
    
    func parseIncomingAttachments(from bodyStructure: String, uid: UInt32) -> [IncomingAttachmentMetadata] {
        print("ATTACHMENT_PARSE: Starting parse for UID \(uid)")
        print("ATTACHMENT_PARSE: BODYSTRUCTURE length: \(bodyStructure.count)")
        
        var attachments: [IncomingAttachmentMetadata] = []
        
        let parts = splitBodyStructureParts(bodyStructure)
        print("ATTACHMENT_PARSE: Found \(parts.count) top-level parts")
        
        for (index, part) in parts.enumerated() {
            let section = "\(index + 1)"
            if let metadata = parseBodyPart(part, section: section, uid: uid) {
                attachments.append(metadata)
            }
        }
        
        print("ATTACHMENT_PARSE: Extracted \(attachments.count) attachments for UID \(uid)")
        return attachments
    }
    
    private func splitBodyStructureParts(_ structure: String) -> [String] {
        var parts: [String] = []
        var currentPart = ""
        var depth = 0
        var inQuotes = false
        
        for char in structure {
            if char == "\"" {
                inQuotes.toggle()
            }
            
            if !inQuotes {
                if char == "(" {
                    depth += 1
                } else if char == ")" {
                    depth -= 1
                }
            }
            
            currentPart.append(char)
            
            if depth == 0 && !currentPart.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(currentPart.trimmingCharacters(in: .whitespaces))
                currentPart = ""
            }
        }
        
        if !currentPart.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(currentPart.trimmingCharacters(in: .whitespaces))
        }
        
        return parts
    }
    
    private func parseBodyPart(_ part: String, section: String, uid: UInt32) -> IncomingAttachmentMetadata? {
        guard part.hasPrefix("(") else { return nil }
        
        let components = extractComponents(from: part)
        guard components.count >= 7 else {
            print("ATTACHMENT_PARSE: Not enough components in section \(section)")
            return nil
        }
        
        let type = components[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        let subtype = components[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        let mimeType = "\(type)/\(subtype)"
        
        if type == "text" && (subtype == "plain" || subtype == "html") {
            print("ATTACHMENT_PARSE: Skipping text part \(section): \(mimeType)")
            return nil
        }
        
        let filename = extractFilename(from: components.count > 2 ? components[2] : "")
            ?? extractFilename(from: components.count > 8 ? components[8] : "")
            ?? "attachment_\(section)"
        
        let sizeBytes = Int64(components.count > 6 ? components[6].trimmingCharacters(in: .whitespaces) : "0") ?? 0
        
        let disposition: AttachmentDisposition = components.count > 8 && components[8].lowercased().contains("inline")
            ? .inline
            : .attachment
        
        let contentId = components.count > 4 ? extractContentId(from: components[4]) : nil
        
        print("ATTACHMENT_PARSE: Found attachment in section \(section): \(filename) (\(mimeType), \(sizeBytes) bytes)")
        
        return IncomingAttachmentMetadata(
            section: section,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            disposition: disposition,
            contentId: contentId
        )
    }
    
    private func extractComponents(from part: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        
        for char in part.dropFirst() {
            if char == "\"" && (current.isEmpty || current.last != "\\") {
                inQuotes.toggle()
                current.append(char)
                continue
            }
            
            if !inQuotes {
                if char == "(" {
                    depth += 1
                } else if char == ")" {
                    depth -= 1
                    if depth < 0 {
                        break
                    }
                }
                
                if char == " " && depth == 0 {
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        components.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                    }
                    continue
                }
            }
            
            current.append(char)
        }
        
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            components.append(current.trimmingCharacters(in: .whitespaces))
        }
        
        return components
    }
    
    private func extractFilename(from component: String) -> String? {
        if component.isEmpty || component == "NIL" {
            return nil
        }
        
        let patterns = [
            "\"?filename\"?\\s*=\\s*\"([^\"]+)\"",
            "\"?name\"?\\s*=\\s*\"([^\"]+)\"",
            "\"([^\"]+\\.[a-zA-Z0-9]{2,5})\""
        ]
        
        for pattern in patterns {
            if let range = component.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let match = String(component[range])
                if let filenameRange = match.range(of: "\"([^\"]+)\"", options: .regularExpression) {
                    let filenameMatch = String(match[filenameRange])
                    return filenameMatch.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        
        return nil
    }
    
    private func extractContentId(from component: String) -> String? {
        if component.isEmpty || component == "NIL" {
            return nil
        }
        
        if let range = component.range(of: "<([^>]+)>", options: .regularExpression) {
            let match = String(component[range])
            return match.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        
        return nil
    }
}

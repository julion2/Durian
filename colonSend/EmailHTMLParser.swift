import Foundation
import AppKit

class EmailHTMLParser {
    
    // MARK: - Public Interface
    
    static func parseHTML(_ html: String) -> NSAttributedString {
        let parser = EmailHTMLParser()
        return parser.convert(html)
    }
    
    // MARK: - Private Implementation
    
    private var attributedString = NSMutableAttributedString()
    private var fontStack: [NSFont] = []
    private var colorStack: [NSColor] = []
    private var linkStack: [URL] = []
    
    private init() {
        // Start with default font and color
        fontStack.append(NSFont.systemFont(ofSize: 13))
        colorStack.append(NSColor.labelColor)
    }
    
    private func convert(_ html: String) -> NSAttributedString {
        // Clean and prepare HTML
        let cleanedHTML = cleanHTML(html)
        
        // Parse HTML tags and content
        parseHTMLContent(cleanedHTML)
        
        return attributedString
    }
    
    private func cleanHTML(_ html: String) -> String {
        var cleaned = html
        
        // Remove script and style content
        cleaned = cleaned.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        
        // Remove comments
        cleaned = cleaned.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        
        // Clean up whitespace
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func parseHTMLContent(_ html: String) {
        let scanner = Scanner(string: html)
        scanner.charactersToBeSkipped = nil
        
        while !scanner.isAtEnd {
            // Scan for text content before next tag
            if let textContent = scanner.scanUpToString("<") {
                appendText(decodeHTMLEntities(textContent))
            }
            
            // Scan for HTML tag
            if scanner.scanString("<") != nil {
                if let tagContent = scanner.scanUpToString(">") {
                    _ = scanner.scanString(">") // consume the closing >
                    processHTMLTag(tagContent)
                }
            }
        }
    }
    
    private func processHTMLTag(_ tagContent: String) {
        let tagContent = tagContent.trimmingCharacters(in: .whitespaces)
        
        // Check if it's a closing tag
        if tagContent.hasPrefix("/") {
            let tagName = String(tagContent.dropFirst()).lowercased()
            handleClosingTag(tagName)
            return
        }
        
        // Parse opening tag and attributes
        let components = tagContent.components(separatedBy: " ")
        guard let tagName = components.first?.lowercased() else { return }
        
        let attributes = parseAttributes(from: tagContent)
        handleOpeningTag(tagName, attributes: attributes)
    }
    
    private func parseAttributes(from tagContent: String) -> [String: String] {
        var attributes: [String: String] = [:]
        
        // Simple attribute parsing: key="value" or key='value'
        let pattern = "(\\w+)=[\"']([^\"']*)[\"']"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let matches = regex?.matches(in: tagContent, options: [], range: NSRange(location: 0, length: tagContent.count)) ?? []
        
        for match in matches {
            if match.numberOfRanges >= 3 {
                let keyRange = Range(match.range(at: 1), in: tagContent)!
                let valueRange = Range(match.range(at: 2), in: tagContent)!
                let key = String(tagContent[keyRange])
                let value = String(tagContent[valueRange])
                attributes[key.lowercased()] = value
            }
        }
        
        return attributes
    }
    
    private func handleOpeningTag(_ tagName: String, attributes: [String: String]) {
        switch tagName {
        case "b", "strong":
            pushBoldFont()
            
        case "i", "em":
            pushItalicFont()
            
        case "u":
            // Underline will be applied as an attribute
            break
            
        case "a":
            if let href = attributes["href"], let url = URL(string: href) {
                linkStack.append(url)
                colorStack.append(NSColor.linkColor)
            }
            
        case "br":
            appendText("\n")
            
        case "p":
            if !attributedString.string.isEmpty && !attributedString.string.hasSuffix("\n") {
                appendText("\n")
            }
            
        case "div":
            if !attributedString.string.isEmpty && !attributedString.string.hasSuffix("\n") {
                appendText("\n")
            }
            
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if !attributedString.string.isEmpty {
                appendText("\n")
            }
            let size: CGFloat = tagName == "h1" ? 20 : tagName == "h2" ? 18 : tagName == "h3" ? 16 : 14
            let font = NSFont.boldSystemFont(ofSize: size)
            fontStack.append(font)
            
        case "ul", "ol":
            appendText("\n")
            
        case "li":
            appendText("\n• ")
            
        case "blockquote":
            appendText("\n> ")
            colorStack.append(NSColor.secondaryLabelColor)
            
        default:
            // Ignore unknown tags
            break
        }
    }
    
    private func handleClosingTag(_ tagName: String) {
        switch tagName {
        case "b", "strong":
            popFont()
            
        case "i", "em":
            popFont()
            
        case "a":
            if !linkStack.isEmpty {
                linkStack.removeLast()
                colorStack.removeLast()
            }
            
        case "p", "div":
            appendText("\n")
            
        case "h1", "h2", "h3", "h4", "h5", "h6":
            appendText("\n")
            popFont()
            
        case "blockquote":
            appendText("\n")
            colorStack.removeLast()
            
        default:
            break
        }
    }
    
    private func pushBoldFont() {
        let currentFont = fontStack.last ?? NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: currentFont.pointSize)
        fontStack.append(boldFont)
    }
    
    private func pushItalicFont() {
        let currentFont = fontStack.last ?? NSFont.systemFont(ofSize: 13)
        let italicFont = NSFont(descriptor: currentFont.fontDescriptor.withSymbolicTraits(.italic), size: currentFont.pointSize) ?? currentFont
        fontStack.append(italicFont)
    }
    
    private func popFont() {
        if fontStack.count > 1 {
            fontStack.removeLast()
        }
    }
    
    private func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        
        let currentFont = fontStack.last ?? NSFont.systemFont(ofSize: 13)
        let currentColor = colorStack.last ?? NSColor.labelColor
        
        var attributes: [NSAttributedString.Key: Any] = [
            .font: currentFont,
            .foregroundColor: currentColor
        ]
        
        // Add link if we're inside an <a> tag
        if let currentLink = linkStack.last {
            attributes[.link] = currentLink
        }
        
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        attributedString.append(attributedText)
    }
    
    private func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        
        // Common HTML entities
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&auml;": "ä",
            "&ouml;": "ö",
            "&uuml;": "ü",
            "&Auml;": "Ä",
            "&Ouml;": "Ö",
            "&Uuml;": "Ü",
            "&szlig;": "ß"
        ]
        
        for (entity, replacement) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        
        return decoded
    }
}
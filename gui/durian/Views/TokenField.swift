//
//  TokenField.swift
//  Durian
//
//  Native NSTokenField wrapper for email addresses
//

import SwiftUI
import AppKit

// MARK: - Compose Field Enum (Shared Focus)

enum ComposeField: Hashable {
    case to
    case cc
    case bcc
    case subject
    case body
}

// MARK: - Token Field (NSTokenField Wrapper)

struct TokenField: NSViewRepresentable {
    @Binding var tokens: [String]
    var focusedField: FocusState<ComposeField?>.Binding
    let fieldIdentifier: ComposeField
    var onCommit: (() -> Void)? = nil
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> NSTokenField {
        let tokenField = NSTokenField()
        tokenField.delegate = context.coordinator
        
        // Styling
        tokenField.isBordered = false
        tokenField.backgroundColor = .clear
        tokenField.drawsBackground = false
        tokenField.focusRingType = .none
        tokenField.font = .systemFont(ofSize: 14)
        
        // Token behavior
        tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",;\n")
        tokenField.tokenStyle = .rounded
        
        // Layout
        tokenField.lineBreakMode = .byClipping
        tokenField.cell?.isScrollable = true
        tokenField.cell?.wraps = false
        
        // Set initial value
        tokenField.objectValue = tokens as NSArray
        
        context.coordinator.tokenField = tokenField
        
        return tokenField
    }
    
    func updateNSView(_ nsView: NSTokenField, context: Context) {
        // Update tokens if changed from outside
        let currentTokens = (nsView.objectValue as? [String]) ?? []
        if currentTokens != tokens {
            nsView.objectValue = tokens as NSArray
        }
        
        // Handle focus
        let shouldBeFocused = focusedField.wrappedValue == fieldIdentifier
        let isFocused = nsView.window?.firstResponder == nsView.currentEditor()
        
        if shouldBeFocused && !isFocused {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TokenField
        weak var tokenField: NSTokenField?
        
        init(_ parent: TokenField) {
            self.parent = parent
        }
        
        // MARK: - Token Field Delegate
        
        func controlTextDidChange(_ notification: Notification) {
            guard let tokenField = notification.object as? NSTokenField else { return }
            
            // Update parent tokens
            if let newTokens = tokenField.objectValue as? [String] {
                if newTokens != parent.tokens {
                    DispatchQueue.main.async {
                        self.parent.tokens = newTokens
                    }
                }
            }
        }
        
        func controlTextDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async {
                self.parent.focusedField.wrappedValue = self.parent.fieldIdentifier
            }
        }
        
        func controlTextDidEndEditing(_ notification: Notification) {
            // Commit any pending tokens
            guard let tokenField = notification.object as? NSTokenField else { return }
            
            if let newTokens = tokenField.objectValue as? [String] {
                DispatchQueue.main.async {
                    self.parent.tokens = newTokens
                    self.parent.onCommit?()
                }
            }
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Enter key - commit tokens
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let tokenField = control as? NSTokenField,
                   let tokens = tokenField.objectValue as? [String] {
                    DispatchQueue.main.async {
                        self.parent.tokens = tokens
                        self.parent.onCommit?()
                    }
                }
                return false // Let NSTokenField handle the tokenization
            }
            
            return false
        }
        
        // MARK: - Token Representation
        
        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            // Display the token as-is (the email address)
            return representedObject as? String
        }
        
        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            // When editing, show the full email
            return representedObject as? String
        }
        
        func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
            // Clean the email when creating a token
            let cleaned = EmailTokenHelper.cleanEmail(editingString)
            return cleaned.isEmpty ? nil : cleaned
        }
        
        func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
            // Use rounded style for all tokens
            return .rounded
        }
        
        func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool {
            // No context menu for now
            return false
        }
    }
}

// MARK: - Email Helper Alias (uses EmailHelper from EmailComposition)

enum EmailTokenHelper {
    static func isValidEmail(_ email: String) -> Bool {
        EmailHelper.isValidEmail(email)
    }
    
    static func cleanEmail(_ input: String) -> String {
        EmailHelper.cleanEmail(input)
    }
}

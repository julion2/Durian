//
//  ComposeToolbar.swift
//  Durian
//
//  Rich text formatting toolbar (visual only, functionality to be added later)
//

import SwiftUI

/// Formatting toolbar for the email composer
/// Currently visual-only - formatting functionality will be added later
struct ComposeToolbar: View {
    @State private var selectedFont: String = "Helvetica"
    @State private var selectedSize: Int = 13
    
    private let availableFonts = ["Helvetica", "Arial", "Times New Roman", "Georgia", "Courier"]
    private let availableSizes = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32]
    
    var body: some View {
        HStack(spacing: 12) {
            // Font Picker
            fontPicker
            
            // Size Picker
            sizePicker
            
            Divider()
                .frame(height: 20)
            
            // Bold, Italic, Underline
            textStyleButtons
            
            Divider()
                .frame(height: 20)
            
            // Alignment
            alignmentButtons
            
            Divider()
                .frame(height: 20)
            
            // Lists
            listButtons
            
            Divider()
                .frame(height: 20)
            
            // Link & Image
            insertButtons
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Font Picker
    
    private var fontPicker: some View {
        Menu {
            ForEach(availableFonts, id: \.self) { font in
                Button(action: { selectedFont = font }) {
                    HStack {
                        Text(font)
                        if font == selectedFont {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedFont)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#0a0a0a"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#0a0a0a"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 120)
            .background(Color(hex: "#f3f3f5"))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Size Picker
    
    private var sizePicker: some View {
        Menu {
            ForEach(availableSizes, id: \.self) { size in
                Button(action: { selectedSize = size }) {
                    HStack {
                        Text("\(size)")
                        if size == selectedSize {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(selectedSize)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#0a0a0a"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#0a0a0a"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 60)
            .background(Color(hex: "#f3f3f5"))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Text Style Buttons (B, I, U)
    
    private var textStyleButtons: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: "bold", action: {})
            ToolbarIconButton(icon: "italic", action: {})
            ToolbarIconButton(icon: "underline", action: {})
        }
    }
    
    // MARK: - Alignment Buttons
    
    private var alignmentButtons: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: "text.alignleft", action: {})
            ToolbarIconButton(icon: "text.aligncenter", action: {})
            ToolbarIconButton(icon: "text.alignright", action: {})
            ToolbarIconButton(icon: "text.justify", action: {})
        }
    }
    
    // MARK: - List Buttons
    
    private var listButtons: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: "list.bullet", action: {})
            ToolbarIconButton(icon: "list.number", action: {})
        }
    }
    
    // MARK: - Insert Buttons (Link, Image)
    
    private var insertButtons: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: "link", action: {})
            ToolbarIconButton(icon: "photo", action: {})
        }
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let icon: String
    let action: () -> Void
    var isActive: Bool = false
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(isActive ? .accentColor : Color(hex: "#4a5565"))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color(hex: "#f3f3f5") : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// Color(hex:) extension is defined in ProfileManager.swift

//
//  SearchPopupView.swift
//  colonSend
//
//  Raycast-style search popup for notmuch queries
//

import SwiftUI

struct SearchPopupView: View {
    @Binding var isPresented: Bool
    @Binding var selectedEmailId: String?
    let onEmailSelected: (String) -> Void
    
    @StateObject private var searchManager = SearchManager()
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isTextFieldFocused: Bool
    
    private let queryHelpers = [
        ("from:", "Sender"),
        ("to:", "Recipient"),
        ("subject:", "Subject"),
        ("tag:", "Tag"),
        ("date:", "Date"),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Input
            searchInputView
            
            Divider()
            
            // Content: Helpers or Results
            if query.isEmpty {
                queryHelpersView
            } else if searchManager.isSearching {
                loadingView
            } else if searchManager.results.isEmpty {
                noResultsView
            } else {
                resultsListView
            }
        }
        .frame(width: 600)
        .frame(maxHeight: 450)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            isTextFieldFocused = true
        }
        .onChange(of: query) { _, newQuery in
            searchManager.search(query: newQuery)
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < searchManager.results.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return) {
            selectCurrentResult()
            return .handled
        }
    }
    
    // MARK: - Subviews
    
    private var searchInputView: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title2)
            
            TextField("Search emails...", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isTextFieldFocused)
            
            if !query.isEmpty {
                Button {
                    query = ""
                    searchManager.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            if searchManager.isSearching {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
    
    private var queryHelpersView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Query helpers")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            HStack(spacing: 8) {
                ForEach(queryHelpers, id: \.0) { prefix, description in
                    Button {
                        query = prefix
                        isTextFieldFocused = true
                    } label: {
                        Text(prefix)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(description)
                }
            }
            
            Text("Use notmuch query syntax for advanced searches")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var loadingView: some View {
        HStack {
            ProgressView()
            Text("Searching...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
    
    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No results for \"\(query)\"")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
    
    private var resultsListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(searchManager.results.enumerated()), id: \.element.id) { index, email in
                        SearchResultRow(
                            email: email,
                            isSelected: index == selectedIndex
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            selectCurrentResult()
                        }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func selectCurrentResult() {
        guard !searchManager.results.isEmpty,
              selectedIndex < searchManager.results.count else { return }
        
        let email = searchManager.results[selectedIndex]
        selectedEmailId = email.id
        onEmailSelected(email.id)
        close()
    }
    
    private func close() {
        searchManager.clear()
        query = ""
        isPresented = false
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let email: MailMessage
    let isSelected: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Unread indicator
            Circle()
                .fill(email.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(senderName)
                        .font(.headline)
                        .fontWeight(email.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(email.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(email.subject.isEmpty ? "(No Subject)" : email.subject)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                if let tags = email.tags, !tags.isEmpty {
                    Text(tags)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
    
    private var senderName: String {
        let from = email.from
        if let range = from.range(of: "<") {
            let namePart = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !namePart.isEmpty { return namePart }
        }
        return from
    }
}

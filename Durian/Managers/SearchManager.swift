//
//  SearchManager.swift
//  Durian
//
//  Manages debounced email search via NotmuchBackend
//

import Foundation

@MainActor
class SearchManager: ObservableObject {
    @Published var results: [MailMessage] = []
    @Published var isSearching: Bool = false
    
    private var searchTask: Task<Void, Never>?
    private let debounceDelay: UInt64 = 300_000_000  // 300ms in nanoseconds
    private let resultLimit: Int = 10
    
    /// Search emails with debounce
    func search(query: String) {
        // Cancel previous search
        searchTask?.cancel()
        
        // Clear results if query is empty
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            isSearching = false
            return
        }
        
        isSearching = true
        
        searchTask = Task {
            // Debounce
            do {
                try await Task.sleep(nanoseconds: debounceDelay)
            } catch {
                return  // Task was cancelled
            }
            
            guard !Task.isCancelled else { return }
            
            // Perform search via NotmuchBackend
            guard let backend = AccountManager.shared.notmuchBackend else {
                results = []
                isSearching = false
                return
            }
            
            let searchResults = await backend.searchAll(query: query, limit: resultLimit)
            
            guard !Task.isCancelled else { return }
            
            results = searchResults
            isSearching = false
        }
    }
    
    /// Clear search results
    func clear() {
        searchTask?.cancel()
        // Wrap in Task to avoid "Publishing changes from within view updates"
        Task { @MainActor in
            results = []
            isSearching = false
        }
    }
}

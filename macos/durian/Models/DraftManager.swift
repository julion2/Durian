//
//  DraftManager.swift
//  Durian
//
//  Local-draft persistence via the durian HTTP API (/local-drafts).
//  Distinct from DraftService, which manages IMAP-synced drafts via the CLI.
//

import Foundation

class DraftManager {
    static let shared = DraftManager()

    private let baseURL = URL(string: "http://localhost:9723/api/v1/local-drafts")!
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    func saveDraft(_ draft: EmailDraft) {
        var cleaned = draft
        cleaned.to = Self.filterValidAddresses(draft.to)
        cleaned.cc = Self.filterValidAddresses(draft.cc)
        cleaned.bcc = Self.filterValidAddresses(draft.bcc)

        do {
            let draftData = try encoder.encode(cleaned)
            let body = try JSONSerialization.data(withJSONObject: [
                "draft_json": try JSONSerialization.jsonObject(with: draftData)
            ])

            var request = URLRequest(url: baseURL.appendingPathComponent(draft.id.uuidString))
            request.httpMethod = "PUT"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 5

            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error {
                    Log.error("DRAFTING", "Failed to save draft: \(error)")
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    Log.debug("DRAFTING", "Draft saved: \(draft.id.uuidString)")
                }
            }.resume()
        } catch {
            Log.error("DRAFTING", "Failed to encode draft: \(error)")
        }
    }

    func loadDraft(id: UUID) -> EmailDraft? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: EmailDraft?

        let url = baseURL.appendingPathComponent(id.uuidString)
        URLSession.shared.dataTask(with: url) { [decoder] data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            struct Wrapper: Decodable {
                let draft_json: EmailDraft
            }
            if let wrapper = try? decoder.decode(Wrapper.self, from: data) {
                var draft = wrapper.draft_json
                draft.to = Self.filterValidAddresses(draft.to)
                draft.cc = Self.filterValidAddresses(draft.cc)
                draft.bcc = Self.filterValidAddresses(draft.bcc)
                result = draft
            }
        }.resume()
        semaphore.wait()
        return result
    }

    func deleteDraft(id: UUID) {
        var request = URLRequest(url: baseURL.appendingPathComponent(id.uuidString))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                Log.error("DRAFTING", "Failed to delete draft: \(error)")
                return
            }
            Log.debug("DRAFTING", "Draft deleted: \(id.uuidString)")
        }.resume()
    }

    func loadAllDrafts() -> [EmailDraft] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [EmailDraft] = []

        URLSession.shared.dataTask(with: baseURL) { [decoder] data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            struct Entry: Decodable {
                let draft_json: EmailDraft
            }
            if let entries = try? decoder.decode([Entry].self, from: data) {
                result = entries.map(\.draft_json)
            }
        }.resume()
        semaphore.wait()
        return result
    }

    /// Filter out addresses that don't contain a valid email (must have @)
    private static func filterValidAddresses(_ addresses: [String]) -> [String] {
        addresses.filter { addr in
            let trimmed = addr.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.contains("@")
        }
    }
}

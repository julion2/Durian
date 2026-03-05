//
//  EventStreamClient.swift
//  Durian
//
//  Lightweight SSE client for real-time new-mail events from durian serve.
//

import Foundation

// MARK: - SSE Event Models

struct NewMailEvent: Decodable {
    let account: String
    let total_new: Int
    let messages: [NewMailMessage]
}

struct NewMailMessage: Decodable {
    let thread_id: String
    let subject: String
    let from: String
    let snippet: String
}

// MARK: - Event Stream Client

@MainActor
class EventStreamClient: ObservableObject {
    @Published var isConnected = false

    private var streamTask: Task<Void, Never>?
    private let eventsURL = URL(string: "http://localhost:9723/api/v1/events")!
    private let reconnectDelay: UInt64 = 5_000_000_000 // 5 seconds

    var onNewMail: ((NewMailEvent) -> Void)?

    // MARK: - Connection

    func connect() {
        guard streamTask == nil else { return }
        Log.debug("EVENTS", "Starting SSE connection...")
        streamTask = Task { await streamLoop() }
    }

    func disconnect() {
        Log.debug("EVENTS", "Disconnecting SSE")
        streamTask?.cancel()
        streamTask = nil
        isConnected = false
    }

    // MARK: - Stream Loop (reconnects on error)

    private func streamLoop() async {
        while !Task.isCancelled {
            guard NetworkMonitor.shared.isConnected else {
                Log.debug("EVENTS", "Offline, waiting to retry...")
                isConnected = false
                try? await Task.sleep(nanoseconds: reconnectDelay)
                continue
            }

            do {
                try await readStream()
            } catch is CancellationError {
                break
            } catch {
                Log.error("EVENTS", "Stream error: \(error.localizedDescription)")
            }

            isConnected = false
            guard !Task.isCancelled else { break }
            Log.warning("EVENTS", "Reconnecting in 5s...")
            try? await Task.sleep(nanoseconds: reconnectDelay)
        }
        isConnected = false
    }

    // MARK: - SSE Parser

    private func readStream() async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: eventsURL)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            Log.warning("EVENTS", "Server returned non-200, will retry")
            return
        }

        isConnected = true
        Log.info("EVENTS", "Connected to SSE stream")

        var currentEvent: String?
        var dataBuffer: String = ""

        for try await line in bytes.lines {
            if Task.isCancelled { break }

            // Heartbeat/comment or empty line — flush any buffered event first
            if line.hasPrefix(":") || line.isEmpty {
                if let eventType = currentEvent, !dataBuffer.isEmpty {
                    handleSSEEvent(type: eventType, data: dataBuffer)
                    dataBuffer = ""
                    currentEvent = nil
                }
                continue
            }

            // Parse SSE fields
            if line.hasPrefix("event:") {
                // New event starting — flush any buffered event first
                // (bytes.lines drops empty lines, so we can't rely on \n\n delimiter)
                if let eventType = currentEvent, !dataBuffer.isEmpty {
                    handleSSEEvent(type: eventType, data: dataBuffer)
                    dataBuffer = ""
                }
                currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if dataBuffer.isEmpty {
                    dataBuffer = value
                } else {
                    dataBuffer += "\n" + value
                }
            }
        }

        // Flush last buffered event when stream ends
        if let eventType = currentEvent, !dataBuffer.isEmpty {
            handleSSEEvent(type: eventType, data: dataBuffer)
        }
    }

    // MARK: - Event Dispatch

    private func handleSSEEvent(type: String, data: String) {
        guard type == "new_mail" else {
            Log.debug("EVENTS", "Unknown event type: \(type)")
            return
        }

        guard let jsonData = data.data(using: .utf8) else { return }

        do {
            let event = try JSONDecoder().decode(NewMailEvent.self, from: jsonData)
            Log.info("EVENTS", "new_mail — \(event.total_new) message(s) for \(event.account)")
            onNewMail?(event)
        } catch {
            Log.error("EVENTS", "Failed to decode new_mail event: \(error)")
        }
    }
}

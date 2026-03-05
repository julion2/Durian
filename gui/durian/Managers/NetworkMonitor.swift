//
//  NetworkMonitor.swift
//  Durian
//
//  Monitors network connectivity using NWPathMonitor
//

import Foundation
import Network

@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    @Published private(set) var isConnected: Bool = true
    @Published private(set) var showReconnectedBanner: Bool = false
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "durian.NetworkMonitor")
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let wasConnected = self.isConnected
                let nowConnected = (path.status == .satisfied)
                self.isConnected = nowConnected
                
                // Show "Back online" briefly when reconnecting
                if !wasConnected && nowConnected {
                    Log.info("NETWORK", "Back online")
                    self.showReconnectedBanner = true
                    
                    // Hide after 3 seconds
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.showReconnectedBanner = false
                } else if wasConnected && !nowConnected {
                    Log.info("NETWORK", "Offline")
                }
            }
        }
        monitor.start(queue: queue)
        Log.info("NETWORK", "Monitor started")
    }
}

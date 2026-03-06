import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.js-lab.durian"
    private static let lock = NSLock()
    private static var loggers: [String: Logger] = [:]
    private static var signposters: [String: OSSignposter] = [:]

    private static func logger(for category: String) -> Logger {
        lock.lock()
        defer { lock.unlock() }
        if let cached = loggers[category] { return cached }
        let l = Logger(subsystem: subsystem, category: category)
        loggers[category] = l
        return l
    }

    static func signposter(for category: String) -> OSSignposter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = signposters[category] { return cached }
        let s = OSSignposter(subsystem: subsystem, category: category)
        signposters[category] = s
        return s
    }

    static func debug(_ cat: String, _ msg: String) {
        logger(for: cat).debug("\(msg, privacy: .public)")
    }

    static func info(_ cat: String, _ msg: String) {
        logger(for: cat).info("\(msg, privacy: .public)")
    }

    static func warning(_ cat: String, _ msg: String) {
        logger(for: cat).warning("\(msg, privacy: .public)")
    }

    static func error(_ cat: String, _ msg: String) {
        logger(for: cat).error("\(msg, privacy: .public)")
    }
}

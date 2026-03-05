import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.js-lab.durian"
    private static var loggers: [String: Logger] = [:]

    private static func logger(for category: String) -> Logger {
        if let cached = loggers[category] { return cached }
        let l = Logger(subsystem: subsystem, category: category)
        loggers[category] = l
        return l
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

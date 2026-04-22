//
//  PklEvaluator.swift
//  Durian
//
//  Evaluates .pkl config files to JSON via the pkl CLI.
//

import Foundation

enum PklEvaluator {
    /// Evaluate a .pkl file and decode the JSON output into the given type.
    static func eval<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let json = try evalJSON(url)
        return try JSONDecoder().decode(type, from: json)
    }

    /// Evaluate a .pkl file and return raw JSON data.
    static func evalJSON(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pkl")
        process.arguments = ["eval", "--format", "json", url.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw PklError.evaluationFailed(errorOutput)
        }

        return stdout.fileHandleForReading.readDataToEndOfFile()
    }
}

enum PklError: LocalizedError {
    case evaluationFailed(String)

    var errorDescription: String? {
        switch self {
        case .evaluationFailed(let msg):
            return "pkl eval failed: \(msg)"
        }
    }
}

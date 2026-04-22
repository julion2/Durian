//
//  PklEvaluator.swift
//  Durian
//
//  Evaluates .pkl config files to JSON via the pkl CLI.
//  Schemas are bundled in the app and extracted to a temp dir at runtime.
//

import Foundation

enum PklEvaluator {
    /// Temp directory with extracted schemas (created once per app launch).
    private static let schemaDir: String? = {
        // Schemas are bundled as resources by Bazel. For dev builds they may
        // not be present — fall back gracefully so pkl eval still works.
        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        let bundledSchema = (resourcePath as NSString).appendingPathComponent("schema")
        guard FileManager.default.fileExists(atPath: bundledSchema) else {
            // Dev fallback: try the repo schema/ directory
            let repoSchema = (resourcePath as NSString)
                .deletingLastPathComponent  // .app/Contents/MacOS
                .appending("/../../../schema")
            if FileManager.default.fileExists(atPath: repoSchema) {
                return repoSchema
            }
            return nil
        }

        return bundledSchema
    }()

    /// Evaluate a .pkl file and decode the JSON output into the given type.
    static func eval<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let json = try evalJSON(url)
        return try JSONDecoder().decode(type, from: json)
    }

    /// Evaluate a .pkl file and return raw JSON data.
    static func evalJSON(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pkl")

        var args = ["eval", "--format", "json"]
        if let sd = schemaDir {
            args += ["--module-path", sd, "--allowed-modules", "file:,modulepath:"]
        }
        args.append(url.path)
        process.arguments = args

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

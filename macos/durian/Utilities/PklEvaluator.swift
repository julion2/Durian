//
//  PklEvaluator.swift
//  Durian
//
//  Evaluates .pkl config files to JSON via the bundled pkl binary.
//  Schemas are bundled as app resources by Bazel.
//

import Foundation

enum PklEvaluator {
    /// Schema directory: looks for Config.pkl in bundle resources.
    private static let schemaDir: String? = {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        for candidate in [
            (resourcePath as NSString).appendingPathComponent("schema"),
            resourcePath,
        ] {
            let test = (candidate as NSString).appendingPathComponent("Config.pkl")
            if FileManager.default.fileExists(atPath: test) {
                return candidate
            }
        }
        return nil
    }()

    /// Pkl binary: bundled in .app, then /usr/local/bin/pkl-durian, then PATH.
    private static let pklBinary: String = {
        // 1. Bundled in .app/Contents/MacOS/pkl
        if let execPath = Bundle.main.executablePath {
            let bundled = ((execPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("pkl")
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        // 2. Installed alongside CLI
        if FileManager.default.fileExists(atPath: "/usr/local/bin/pkl-durian") {
            return "/usr/local/bin/pkl-durian"
        }
        // 3. User's own pkl (brew install pkl)
        return "/opt/homebrew/bin/pkl"
    }()

    /// Evaluate a .pkl file and decode the JSON output into the given type.
    static func eval<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let json = try evalJSON(url)
        return try JSONDecoder().decode(type, from: json)
    }

    /// Evaluate a .pkl file and return raw JSON data.
    static func evalJSON(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pklBinary)

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

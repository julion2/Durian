//
//  PklEvaluator.swift
//  Durian
//
//  Evaluates .pkl config files to JSON via the pkl CLI.
//  Schemas are bundled as app resources by Bazel.
//

import Foundation

enum PklEvaluator {
    /// Schema directory inside the app bundle (set by Bazel resources).
    private static let schemaDir: String? = {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        // Bazel places filegroup resources at the bundle root under their workspace-relative path.
        // schema/*.pkl files end up at <app>/Contents/Resources/schema/
        for candidate in [
            (resourcePath as NSString).appendingPathComponent("schema"),
            resourcePath,  // files may be placed flat in Resources/
        ] {
            let test = (candidate as NSString).appendingPathComponent("Config.pkl")
            if FileManager.default.fileExists(atPath: test) {
                return candidate
            }
        }
        return nil
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

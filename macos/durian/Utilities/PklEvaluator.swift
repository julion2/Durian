//
//  PklEvaluator.swift
//  Durian
//
//  Evaluates .pkl config files via pkl-swift library.
//  Schemas are bundled as app resources and served via modulePaths.
//

import Foundation
import PklSwift

enum PklEvaluator {
    /// Ensure pkl binary is findable even when launched from Dock/Spotlight
    /// (macOS apps don't inherit shell PATH).
    private static let _ensurePklPath: Void = {
        if ProcessInfo.processInfo.environment["PKL_EXEC"] != nil { return }

        // Known install locations first, then search PATH
        let found = ["/opt/homebrew/bin/pkl", "/usr/local/bin/pkl"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? findInPath("pkl")

        if let found {
            setenv("PKL_EXEC", found, 0)
        }
    }()

    private static func findInPath(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for p in paths {
            let full = "\(p)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    /// Schema directory inside the app bundle.
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

    /// Evaluate a .pkl file and decode directly into the given type via pkl-swift.
    static func eval<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        _ = _ensurePklPath
        var options = EvaluatorOptions.preconfigured
        if let sd = schemaDir {
            options.modulePaths = [sd]
        }

        return try await withEvaluator(options: options) { evaluator in
            try await evaluator.evaluateModule(
                source: .path(url.path),
                as: type
            )
        }
    }
}

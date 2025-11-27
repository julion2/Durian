#!/bin/bash

echo "🔧 Fixing colonMime Package.swift for VMime..."
echo ""

COLONMIME_PATH="/Users/julianschenker/Documents/projects/colonMime"

if [ ! -d "$COLONMIME_PATH" ]; then
    echo "❌ colonMime not found at $COLONMIME_PATH"
    exit 1
fi

cd "$COLONMIME_PATH"

# Backup
cp Package.swift Package.swift.backup
echo "✅ Backup created: Package.swift.backup"

# Write new Package.swift with VMime paths
cat > Package.swift << 'PKGEOF'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ColonMime",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ColonMime", targets: ["ColonMime"]),
    ],
    targets: [
        .target(
            name: "ColonMimeCore",
            dependencies: [],
            path: "Sources/ColonMimeCore",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/ColonMime"),
                .unsafeFlags(["-I/Users/julianschenker/.local/include"]),
                .unsafeFlags(["-std=c++17"]),
                .define("VMIME_HAVE_MESSAGING_FEATURES", to: "0"),
            ],
            cxxLanguageStandard: .cxx17,
            linkerSettings: [
                .unsafeFlags([
                    "-L/Users/julianschenker/.local/lib",
                    "-lvmime",
                    "-Wl,-rpath,/Users/julianschenker/.local/lib"
                ])
            ]
        ),
        .target(
            name: "ColonMime",
            dependencies: ["ColonMimeCore"],
            path: "Sources/ColonMime",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "ColonMimeTests",
            dependencies: ["ColonMime"],
            path: "Tests/ColonMimeTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
PKGEOF

echo "✅ Package.swift updated with VMime paths"
echo ""
echo "📋 Next steps in Xcode:"
echo "1. Open colonSend.xcodeproj"
echo "2. Project Navigator → colonSend (blue icon)"
echo "3. Package Dependencies tab"
echo "4. Select 'colonMime' → Click '-' (Remove)"
echo "5. Click '+' (Add Package)"
echo "6. Choose 'Add Local...'"
echo "7. Navigate to: $COLONMIME_PATH"
echo "8. Click 'Add Package'"
echo "9. Cmd+Shift+K (Clean)"
echo "10. Cmd+B (Build)"
echo ""
echo "See VMIME_FIX_GUIDE.md for details"

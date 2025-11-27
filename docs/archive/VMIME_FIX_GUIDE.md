# VMime Fix für colonMime Package

## Problem

```
'vmime/vmime.hpp' file not found
```

Das colonMime Package von GitHub kennt die VMime-Pfade auf deinem System nicht.

## Lösung: Lokales Package verwenden

### Schritt 1: Lokale colonMime Package.swift anpassen

```bash
cd /Users/julianschenker/Documents/projects/colonMime
```

Öffne `Package.swift` und füge bei `ColonMimeCore` Target die VMime-Pfade hinzu:

```swift
.target(
    name: "ColonMimeCore",
    dependencies: [],
    path: "Sources/ColonMimeCore",
    sources: ["src"],
    publicHeadersPath: "include",
    cxxSettings: [
        .headerSearchPath("include"),
        .headerSearchPath("include/ColonMime"),
        
        // ✅ DIESE ZEILEN HINZUFÜGEN:
        .unsafeFlags([
            "-I\(ProcessInfo.processInfo.environment["HOME"] ?? ""!)/.local/include"
        ]),
        
        .unsafeFlags(["-std=c++17"]),
        .define("VMIME_HAVE_MESSAGING_FEATURES", to: "0"),
    ],
    cxxLanguageStandard: .cxx17,
    linkerSettings: [
        // ✅ DIESE ZEILEN HINZUFÜGEN:
        .unsafeFlags([
            "-L\(ProcessInfo.processInfo.environment["HOME"] ?? ""!)/.local/lib",
            "-lvmime"
        ])
    ]
),
```

**ODER einfacher mit festen Pfaden:**

```swift
cxxSettings: [
    .headerSearchPath("include"),
    .headerSearchPath("include/ColonMime"),
    .unsafeFlags(["-I/Users/julianschenker/.local/include"]),
    .unsafeFlags(["-std=c++17"]),
    .define("VMIME_HAVE_MESSAGING_FEATURES", to: "0"),
],
linkerSettings: [
    .unsafeFlags([
        "-L/Users/julianschenker/.local/lib",
        "-lvmime"
    ])
]
```

### Schritt 2: In Xcode auf lokales Package umstellen

1. **Öffne Xcode**
2. **Project Navigator** → colonSend (Projekt, blaues Icon)
3. **Package Dependencies** Tab
4. Wähle `colonMime` aus der Liste
5. Klicke `-` (Remove)
6. Klicke `+` (Add Package)
7. Wähle **"Add Local..."**
8. Navigiere zu: `/Users/julianschenker/Documents/projects/colonMime`
9. Add Package

### Schritt 3: Build

```
Cmd+Shift+K (Clean)
Cmd+B (Build)
```

## Alternative: Quick Fix Script

```bash
cd /Users/julianschenker/Documents/projects/colonMime

# Backup
cp Package.swift Package.swift.backup

# Ersetze die cxxSettings Sektion
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
```

Dann in Xcode:
- Remove GitHub colonMime Package
- Add Local Package (obiger Pfad)
- Clean + Build

## Verifizierung

Nach dem Build solltest du sehen:

```
✅ Building ColonMimeCore...
✅ Compiling MimePart.cpp
✅ Compiling MimeMessage.cpp
✅ Compiling SwiftBridge.cpp
✅ Build succeeded
```

## Troubleshooting

### Fehler: "unsafe flags not allowed"
→ In der `Package.swift` den Pfad anpassen oder Environment-Variable nutzen

### Fehler: "library not found for -lvmime"
→ Prüfe: `ls ~/.local/lib/libvmime.dylib`
→ Falls nicht da: VMime neu installieren (siehe VMIME_XCODE_SETUP.md)

### Build erfolgreich, aber Runtime Error
→ Füge Runpath hinzu: `-Wl,-rpath,/Users/julianschenker/.local/lib`

## Zusammenfassung

1. **Lokale** colonMime/Package.swift anpassen (VMime-Pfade hinzufügen)
2. In **Xcode**: GitHub Package entfernen
3. In **Xcode**: Lokales Package hinzufügen
4. **Clean + Build**

Fertig! 🎉

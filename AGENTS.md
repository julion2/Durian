# Agent Guidelines for colonSend

## Build & Test Commands
- **Build**: `xcodebuild -scheme colonSend -configuration Debug build`
- **Run**: Open Xcode and run the colonSend target (no CLI test/run commands available)
- **No automated tests**: This project does not have a test suite

## SMTP Testing
- **Test SMTP Connectivity**: `nc -v smtp.ethereal.email 587` or `nc -v mail.gmx.net 587`
- **Check SMTP Capabilities**: `openssl s_client -connect smtp.ethereal.email:587 -starttls smtp`
- **Send Test Email**: Use Compose UI (Cmd+N), send to test account, verify receipt in web client
- **Drafts Location**: `~/.config/colonSend/drafts/` - auto-saved as JSON files

## Code Style & Conventions

**Language**: Swift (macOS SwiftUI app)

**Imports**: Foundation first, then SwiftUI/AppKit, then third-party (NIO*, Combine), alphabetically within groups

**File Headers**: Include comment header with filename and brief description (see Models/IMAPModels.swift:1-6)

**Formatting**: 4-space indentation, opening braces on same line, `MARK:` comments for sections

**Types**: Explicit types for @Published properties, inference elsewhere; use structs for models, classes with @MainActor for ObservableObject

**Naming**: camelCase for properties/functions, PascalCase for types; descriptive names (e.g., `updateAggregatedData`, not `update`)

**Error Handling**: Use `Result<T, Error>` for async completions, custom `IMAPError` enum for domain errors, print without emoji prefixes (🔵 info, ❌ error, 🔧 debug)

**Architecture**: Single Responsibility - separate Models/, Managers/, Network/, Utilities/ as per REFACTORING.md; extensions for utilities on IMAPClient; use @Published for observable state; AccountManager.shared singleton pattern

**Async**: Use async/await for network operations, @MainActor for UI-bound classes, Task for bridging sync to async

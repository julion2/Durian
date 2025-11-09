import Foundation

let projectPath = "colonSend.xcodeproj/project.pbxproj"
let packagePath = "/Users/julianschenker/Documents/projects/colonMime"

print("Adding local colonMime package...")

// This would need pbxproj manipulation
// Easier to do in Xcode UI

print("✅ Please add via Xcode UI:")
print("1. File → Add Package Dependencies")
print("2. Click 'Add Local...' button (bottom left)")
print("3. Navigate to: \(packagePath)")
print("4. Click 'Add Package'")

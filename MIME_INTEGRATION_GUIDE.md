# Integration deiner MIME Library in colonSend

## Setup

### 1. Private GitHub Repository hinzufügen

**In Xcode:**
```
File → Add Package Dependencies
URL: https://github.com/dein-username/deine-mime-library.git
```

**Für private Repos brauchst du:**
- GitHub Personal Access Token
- Xcode → Settings → Accounts → GitHub → Personal Access Token eingeben

**Erstelle Token auf GitHub:**
1. GitHub.com → Settings → Developer Settings
2. Personal Access Tokens → Tokens (classic)
3. Generate new token
4. Scopes: `repo` (für private Repos)
5. Token kopieren und in Xcode einfügen

### 2. In colonSend Code verwenden

Angenommen deine Library heißt `MimeParser`:

```swift
// In IMAPClient.swift
import MimeParser  // Deine Library

extension IMAPClient {
    
    func parseEmailWithMimeParser(_ rawEmail: String) -> (String, [Attachment]) {
        do {
            // Nutze deine Library API
            let parsed = try MimeMessage.parse(rawEmail)
            
            let body = parsed.textBody ?? parsed.htmlBody ?? ""
            let attachments = parsed.attachments.map { att in
                Attachment(
                    filename: att.filename,
                    data: att.data,
                    mimeType: att.contentType
                )
            }
            
            return (body, attachments)
            
        } catch {
            print("MIME_PARSE_ERROR: \(error)")
            return ("", [])
        }
    }
}
```

### 3. Ersetze bestehende MIME-Parsing-Logik

```swift
// Ersetze in IMAPClient.swift:

// ALT:
private func parseMimeContent(_ content: String) -> (String, NSAttributedString?) {
    // 200+ Zeilen custom parsing...
}

// NEU:
private func parseMimeContent(_ content: String) -> (String, NSAttributedString?) {
    let (text, attachments) = parseEmailWithMimeParser(content)
    
    // Falls HTML vorhanden, konvertiere zu NSAttributedString
    let attributed = text.contains("<html") 
        ? EmailHTMLParser.parseHTML(text) 
        : nil
    
    return (text, attributed)
}
```

### 4. VMime Build Settings (falls nötig)

Falls deine Library VMime nutzt, füge in Xcode Build Settings hinzu:

**Header Search Paths:**
```
$(HOME)/.local/include
/usr/local/include
/opt/homebrew/include
```

**Library Search Paths:**
```
$(HOME)/.local/lib
/usr/local/lib
/opt/homebrew/lib
```

**Other Linker Flags:**
```
-lvmime
```

### 5. Alternative: Git Submodule

Falls du die Library als Submodule einbinden willst:

```bash
cd /Users/julianschenker/Documents/projects/colonSend
git submodule add https://github.com/dein-username/deine-mime-library.git Packages/MimeParser
git submodule update --init --recursive
```

Dann in Xcode:
```
File → Add Local Package
Select: Packages/MimeParser
```

## Beispiel-Mapping

### Von deiner Library API → colonSend Types

```swift
// Deine Library hat vermutlich:
class MimeMessage {
    var subject: String
    var from: String
    var to: [String]
    var textBody: String?
    var htmlBody: String?
    var attachments: [MimeAttachment]
}

class MimeAttachment {
    var filename: String
    var data: Data
    var contentType: String
    var contentId: String?
}

// Mapping zu colonSend:
extension IncomingAttachmentMetadata {
    init(from mimeAtt: MimeAttachment, section: String, uid: UInt32) {
        self.init(
            id: UUID(),
            section: section,
            filename: mimeAtt.filename,
            mimeType: mimeAtt.contentType,
            sizeBytes: Int64(mimeAtt.data.count),
            disposition: mimeAtt.contentId != nil ? .inline : .attachment,
            contentId: mimeAtt.contentId
        )
    }
}
```

## Testing

```swift
// In Tests hinzufügen
func testMimeParserIntegration() throws {
    let testEmail = """
    From: test@example.com
    Subject: Test
    Content-Type: text/plain
    
    Body
    """
    
    let (body, attachments) = parseEmailWithMimeParser(testEmail)
    XCTAssertFalse(body.isEmpty)
}
```

## GitHub Authentication für private Repos

### GitHub Personal Access Token erstellen

```bash
# 1. Gehe zu GitHub
open https://github.com/settings/tokens

# 2. Generate new token (classic)
# 3. Scopes auswählen:
#    ✅ repo (full control of private repos)

# 4. Token kopieren (nur einmal sichtbar!)

# 5. In Xcode einfügen:
# Xcode → Settings → Accounts → Add (+) → GitHub
# Token einfügen
```

### SSH statt HTTPS (Alternative)

```bash
# Wenn du SSH Keys nutzt:
git config --global url."git@github.com:".insteadOf "https://github.com/"

# Dann in Xcode die SSH URL verwenden:
# git@github.com:dein-username/deine-mime-library.git
```

## Troubleshooting

### "Authentication failed"
- Prüfe Personal Access Token ist noch gültig
- Token muss `repo` scope haben
- In Xcode: Settings → Accounts → Prüfe GitHub Account

### "Package not found"
- Repository muss Package.swift enthalten
- Branch/Tag muss existieren
- Bei privaten Repos: Authentifizierung prüfen

### "Undefined symbols for vmime"
```bash
# VMime installieren
brew install cmake
cd ~/Downloads
git clone https://github.com/kisli/vmime.git
cd vmime
cmake -B build -DCMAKE_INSTALL_PREFIX=$HOME/.local
cmake --build build
cmake --install build

# In Xcode Build Settings hinzufügen:
# Header Search Paths: $(HOME)/.local/include
# Library Search Paths: $(HOME)/.local/lib
# Other Linker Flags: -lvmime
```

## Fragen?

1. **Wie heißt deine MIME Library genau?**
2. **Welche API bietet sie? (z.B. welche Klassen/Functions)**
3. **Nutzt sie VMime intern oder eine andere Library?**
4. **Ist sie als Swift Package strukturiert? (Package.swift vorhanden)**

Gib mir diese Infos und ich helfe dir mit der exakten Integration!

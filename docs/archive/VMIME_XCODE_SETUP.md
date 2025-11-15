# VMime Xcode Setup für colonSend

## ✅ VMime ist installiert!

VMime wurde erfolgreich nach `~/.local` installiert:
- **Library**: `~/.local/lib/libvmime.dylib`
- **Headers**: `~/.local/include/vmime/`

## 🔧 Xcode Build Settings konfigurieren

### Methode 1: Über Xcode UI (Empfohlen)

1. **Öffne colonSend.xcodeproj**

2. **Wähle das colonSend Target**:
   - Project Navigator → colonSend (blaues Icon)
   - Targets → colonSend

3. **Build Settings Tab**:
   - Suche nach "Header Search Paths"
   - Füge hinzu: `$(HOME)/.local/include`
   
   - Suche nach "Library Search Paths"
   - Füge hinzu: `$(HOME)/.local/lib`
   
   - Suche nach "Other Linker Flags"
   - Füge hinzu: `-lvmime`
   
   - Suche nach "Runpath Search Paths"
   - Füge hinzu: `$(HOME)/.local/lib`

4. **Clean Build Folder**: Cmd+Shift+K

5. **Build**: Cmd+B

### Methode 2: Via .xcconfig File

1. **In Xcode**:
   - File → Add Files to "colonSend"
   - Wähle `VMime.xcconfig`
   - ✅ "Add to targets: colonSend"

2. **Project Settings**:
   - Project Navigator → colonSend (Projekt, nicht Target)
   - Info Tab
   - Configurations → Debug
   - Set "Based on configuration file" → VMime

3. **Rebuild**:
   - Cmd+Shift+K (Clean)
   - Cmd+B (Build)

## 🧪 Verifizierung

Nach dem Build solltest du sehen:

```
✅ Building colonSend...
✅ Compiling MimePart.cpp
✅ Compiling MimeMessage.cpp
✅ Compiling SwiftBridge.cpp
✅ Linking colonSend
✅ Build succeeded
```

Falls Fehler:

### "vmime/vmime.hpp not found"
```bash
# Prüfe Installation
ls ~/.local/include/vmime/vmime.hpp

# Falls nicht da: VMime neu installieren
cd /Users/julianschenker/Documents/projects/colonSend/.build/vmime
cmake --install build
```

### "ld: library 'vmime' not found"
```bash
# Prüfe Library
ls ~/.local/lib/libvmime.dylib

# Prüfe Library Search Paths in Xcode
# Build Settings → Library Search Paths → sollte $(HOME)/.local/lib enthalten
```

### "dyld: Library not loaded: libvmime.1.dylib"
```bash
# Runtime Path fehlt
# Build Settings → Runpath Search Paths → Füge hinzu: $(HOME)/.local/lib
```

## 📝 Alternative: System-weite Installation

Falls du VMime system-weit installieren willst:

```bash
cd /Users/julianschenker/Documents/projects/colonSend/.build/vmime
sudo cmake --install build --prefix /usr/local
```

Dann in Xcode:
- Header Search Paths: `/usr/local/include`
- Library Search Paths: `/usr/local/lib`

## 🎯 Nächster Schritt

Nach erfolgreichem Build:

```bash
# App starten
# Cmd+R in Xcode

# Console-Logs prüfen
# Window → Debug Area → Console

# Schaue nach:
📧 COLONMIME: Starting RFC-compliant MIME parsing
📧 COLONMIME: Successfully parsed email
```

## 🔍 Debug-Tipps

### Build-Logs prüfen:
1. Xcode → Report Navigator (⌘9)
2. Letzter Build
3. Suche nach "vmime" oder "ColonMimeCore"

### Linker-Flags prüfen:
```bash
# In Build Log suchen nach:
Ld ... -lvmime ...

# Sollte enthalten:
-L/Users/julianschenker/.local/lib -lvmime
```

## ✅ Fertig!

Sobald der Build erfolgreich ist, sollte colonMime vollständig funktionieren und RFC-konformes MIME-Parsing über VMime bereitstellen.

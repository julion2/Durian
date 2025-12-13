# Vim-Style Keybindings für colonSend

## Übersicht

colonSend unterstützt ein vollständiges Vim-Style Key-Sequence System mit Count-Unterstützung.

## Key-Sequence System

Das System unterstützt:
- **Einzelne Tasten**: `j`, `k`, `o`, `c`, `r`, `f`
- **Sequenzen**: `gg`, `dd`, `gi`, `gs`
- **Count-Prefix**: `5j`, `12k`, `3dd`
- **UI-Feedback**: Zeigt aktuelle Sequenz unten rechts an

### Wie es funktioniert

1. Taste drücken → Buffer sammelt Keys
2. Match prüfen:
   - **Full Match** → Action ausführen
   - **Partial Match** → Auf mehr Keys warten
   - **No Match** → Buffer leeren
3. Timeout nach 500ms → Buffer leeren

## Navigation

| Sequenz | Aktion | Beschreibung |
|---------|--------|--------------|
| `j` | Nächste Email | Wählt nächste Email aus |
| `k` | Vorherige Email | Wählt vorherige Email aus |
| `5j` | 5× Nächste | 5 Emails nach unten |
| `10k` | 10× Vorherige | 10 Emails nach oben |
| `gg` | Erste Email | Springt zur ersten Email |
| `G` | Letzte Email | Springt zur letzten Email (Shift+G) |

## Email-Aktionen

| Sequenz | Aktion | Beschreibung |
|---------|--------|--------------|
| `o` | Email öffnen | Öffnet ausgewählte Email |
| `c` | Compose | Neue Email verfassen |
| `r` | Reply | Auf Email antworten |
| `R` | Reply All | Allen antworten (Shift+R) |
| `f` | Forward | Email weiterleiten |
| `u` | Toggle Read | Read/Unread umschalten |
| `dd` | Delete | Email löschen (mit Count: 3dd) |
| `s` | Toggle Star | Stern umschalten |

## View Control

| Sequenz | Aktion | Beschreibung |
|---------|--------|--------------|
| `q` | Quit/Back | Detail-Ansicht schließen |
| `Escape` | Clear | Buffer leeren / Zurück |

## Folder Navigation (Go-Commands)

| Sequenz | Aktion | Beschreibung |
|---------|--------|--------------|
| `gi` | Go Inbox | Wechselt zur Inbox |
| `gs` | Go Sent | Wechselt zu Gesendet |
| `gd` | Go Drafts | Wechselt zu Entwürfe |
| `ga` | Go Archive | Wechselt zu Archiv |

## Legacy Keymaps (mit Modifier)

Diese werden über `keymaps.toml` definiert:

| Tastenkombination | Aktion |
|-------------------|--------|
| `Cmd+r` | Inbox neu laden |
| `Cmd+Shift+K` | Keymaps neu laden |

## UI-Indikator

Wenn du eine Sequenz tippst, erscheint unten rechts ein kleiner Indikator:

```
┌──────────────┐
│ ⌨️  5j       │
└──────────────┘
```

Der verschwindet nach:
- Erfolgreicher Action
- Timeout (500ms)
- Escape drücken
- Ungültige Sequenz

## Konfiguration

Die Sequenzen sind in `colonSend/Keymaps/SequenceMatcher.swift` definiert:

```swift
let sequences: [SequenceDefinition] = [
    SequenceDefinition("j", .nextEmail, "Next email"),
    SequenceDefinition("gg", .firstEmail, "First email"),
    // ...
]
```

### Timeout anpassen

In `KeyBuffer.swift`:
```swift
init(timeout: TimeInterval = 0.5) // 500ms default
```

## Count-Unterstützung

Nicht alle Aktionen unterstützen Counts:

| Aktion | Count Support |
|--------|---------------|
| `nextEmail` | ✅ Ja |
| `prevEmail` | ✅ Ja |
| `deleteEmail` | ✅ Ja |
| `pageDown` | ✅ Ja |
| `pageUp` | ✅ Ja |
| `compose` | ❌ Nein |
| `reply` | ❌ Nein |
| `forward` | ❌ Nein |
| `firstEmail` | ❌ Nein |

## Architektur

```
┌─────────────────────────────────────────────────────────────────┐
│                     KeySequenceEngine                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │ KeyBuffer    │───▶│SequenceMatcher│───▶│ ActionDispatch│    │
│  │              │    │              │    │              │      │
│  │ "5" "j"      │    │ Matches:     │    │ Execute:     │      │
│  │ "g" "g"      │    │ - count: 5   │    │ next_email   │      │
│  │ "d" "d"      │    │ - action: j  │    │ × 5 times    │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────┐                                              │
│  │ TimeoutTimer │  500ms - clears buffer if no input           │
│  └──────────────┘                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Dateien

| Datei | Beschreibung |
|-------|--------------|
| `Keymaps/KeymapTypes.swift` | Enums, Typen, KeymapAction |
| `Keymaps/KeyBuffer.swift` | Key-Sammlung mit Timeout |
| `Keymaps/SequenceMatcher.swift` | Pattern Matching |
| `Keymaps/KeySequenceEngine.swift` | Hauptlogik |
| `KeymapHandler.swift` | NSEvent Integration |

## Troubleshooting

### Sequenz wird nicht erkannt

1. Prüfe die Logs: `print("KEYSEQ: ...")`
2. Prüfe ob Action in SequenceMatcher definiert ist
3. Prüfe ob Handler registriert ist

### UI-Indikator erscheint nicht

1. Prüfe `keymapsManager.keymaps.globalSettings.keymapsEnabled`
2. App muss im Vordergrund sein

### Count funktioniert nicht

Prüfe `supportsCount` in `KeymapAction`:
```swift
var supportsCount: Bool {
    switch self {
    case .nextEmail, .prevEmail: return true
    default: return false
    }
}
```

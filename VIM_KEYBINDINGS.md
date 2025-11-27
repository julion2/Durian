# Vim-Style Keybindings für colonSend

## Übersicht

colonSend unterstützt Vim-inspirierte Keybindings für schnelle Keyboard-Navigation.

## Navigation (Email-Liste)

| Tastenkombination | Aktion | Beschreibung |
|-------------------|--------|--------------|
| `j` / `↓` | Nächste Email | Wählt die nächste Email in der Liste aus |
| `k` / `↑` | Vorherige Email | Wählt die vorherige Email in der Liste aus |
| `Shift+G` | Letzte Email | Springt zur letzten Email in der Liste |
| `Ctrl+d` | Page Down | Eine Seite nach unten scrollen |
| `Ctrl+u` | Page Up | Eine Seite nach oben scrollen |

## Email-Aktionen

| Tastenkombination | Aktion | Beschreibung |
|-------------------|--------|--------------|
| `o` / `Enter` | Email öffnen | Öffnet die ausgewählte Email |
| `c` | Compose | Neue Email verfassen |
| `r` | Reply | Auf ausgewählte Email antworten |
| `f` | Forward | Ausgewählte Email weiterleiten |
| `u` | Toggle Read | Markiert Email als gelesen/ungelesen |
| `Escape` / `q` | Zurück | Schließt Detail-Ansicht (q ist disabled by default) |

## Folder-Aktionen

| Tastenkombination | Aktion | Beschreibung |
|-------------------|--------|--------------|
| `Cmd+r` | Reload | Lädt den aktuellen Folder neu |

## Deaktivierte Keybindings (Standard)

Diese Keybindings sind definiert, aber standardmäßig deaktiviert. Du kannst sie in `~/.config/colonSend/keymaps.toml` aktivieren:

| Tastenkombination | Aktion | Hinweis |
|-------------------|--------|---------|
| `g` (double-tap) | Erste Email | `enabled = false` (Konflikt mit einzelnem 'g') |
| `Shift+r` | Reply All | `enabled = false` (Konflikt mit 'r') |
| `d` | Delete | `enabled = false` (gefährlich ohne Bestätigung) |
| `s` | Toggle Star | `enabled = false` (noch nicht implementiert) |
| `q` | Quit View | `enabled = false` (Escape bevorzugt) |
| `/` | Search | `enabled = false` (noch nicht implementiert) |

## Konfiguration

Alle Keybindings sind in `~/.config/colonSend/keymaps.toml` konfigurierbar:

```toml
[[keymaps]]
action = "next_email"
key = "j"
modifiers = []
description = "Select next email (vim down)"
enabled = true
```

### Keybinding aktivieren/deaktivieren

Setze `enabled = true` oder `enabled = false` für jedes Keybinding.

### Keybinding ändern

Ändere den `key` und/oder `modifiers` Wert:

```toml
[[keymaps]]
action = "reply"
key = "r"
modifiers = ["cmd"]  # Ändert zu Cmd+r
enabled = true
```

### Verfügbare Modifiers

- `"cmd"` - Command/⌘
- `"shift"` - Shift/⇧
- `"option"` - Option/⌥
- `"ctrl"` - Control/⌃

### Global Settings

```toml
[global_settings]
keymaps_enabled = true        # Alle Keybindings aktivieren/deaktivieren
show_keymap_hints = true      # Zeigt Keymap-Hinweise (noch nicht implementiert)
```

## Keybindings neu laden

Nach Änderungen in `keymaps.toml`:
- **App neu starten** (empfohlen)
- Oder: Menü → **Reload Keymaps** (`Cmd+r`)

## Bekannte Einschränkungen

1. **Kein Vim-Mode System**: Es gibt keinen separaten Normal/Insert/Command Mode
2. **Keine Key-Sequenzen**: `gg` (double-tap) wird noch nicht unterstützt
3. **Kein Leader-Key**: Keine Space-basierte Leader-Key-Sequenzen
4. **Focus-Handling**: Keybindings funktionieren nur wenn die App im Vordergrund ist

## Zukünftige Features

- [ ] Vim-Mode System (Normal/Insert/Command)
- [ ] Key-Sequenzen (`gg`, `gi`, etc.)
- [ ] Leader-Key Support (Space als Leader)
- [ ] Visual Mode für Mehrfachauswahl
- [ ] Search mit `/`
- [ ] Email-Markierungen (`m` + key)
- [ ] Quick-Jump zu Folders (`g`+`i`/`s`/`d`)

## Troubleshooting

### Keybindings funktionieren nicht

1. Prüfe `keymaps_enabled = true` in `keymaps.toml`
2. Prüfe `enabled = true` für spezifische Keybindings
3. App neu starten
4. Prüfe Logs: `print("KEYMAPS: ...")`

### Konflikt mit System-Shortcuts

Wenn ein Keybinding mit einem macOS System-Shortcut kollidiert:
1. Ändere das Keybinding in `keymaps.toml`
2. Oder deaktiviere das System-Shortcut in **Systemeinstellungen → Tastatur → Shortcuts**

### Keybinding wird nicht erkannt

Prüfe die exakte Key-Schreibweise in TOML:
- Buchstaben: `"j"`, `"k"`, `"r"`
- Pfeiltasten: `"Up"`, `"Down"`, `"Left"`, `"Right"`
- Spezial: `"Return"`, `"Escape"`, `"Delete"`, `"Space"`
- Groß/Klein: `"G"` + `modifiers = ["shift"]` für Shift+G

## Beispiel-Konfiguration

```toml
# Minimal vim-style config
[global_settings]
keymaps_enabled = true
show_keymap_hints = true

# Basic navigation
[[keymaps]]
action = "next_email"
key = "j"
modifiers = []
enabled = true

[[keymaps]]
action = "prev_email"
key = "k"
modifiers = []
enabled = true

# Actions
[[keymaps]]
action = "open_email"
key = "o"
modifiers = []
enabled = true

[[keymaps]]
action = "reply"
key = "r"
modifiers = []
enabled = true
```

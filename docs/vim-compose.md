# Vim Mode — Compose Editor

The compose editor supports vim-style modal editing. Toggle with `Escape` (insert → normal) and configurable exit sequences (e.g. `jk`).

## Modes

| Mode | Description |
|------|-------------|
| Insert | Normal typing, like a regular editor |
| Normal | Navigation and editing commands |
| Visual | Character-wise selection (`v`) |
| Visual Line | Line-wise selection (`V`) |

## Navigation

| Key | Action |
|-----|--------|
| `h` `j` `k` `l` | Left, down, up, right |
| `w` | Next word |
| `b` | Previous word |
| `e` | End of word |
| `0` | Beginning of line |
| `$` | End of line |
| `gg` | Top of document |
| `G` | Bottom of document |
| `%` | Jump to matching bracket |
| `f`/`F` + char | Find char forward/backward |
| `t`/`T` + char | Find char (till) forward/backward |
| `;` `,` | Repeat last find / reverse |

All navigation commands support count prefixes (e.g. `5j` moves down 5 lines).

## Operators

| Key | Action |
|-----|--------|
| `d` + motion | Delete |
| `c` + motion | Change (delete + insert mode) |
| `y` + motion | Yank (copy) |
| `dd` | Delete line |
| `cc` | Change line |
| `yy` | Yank line |
| `D` | Delete to end of line |
| `C` | Change to end of line |

## Text Objects

Operators can be combined with text objects: `d`/`c`/`y` + `i`/`a` + object.

| Key | Object |
|-----|--------|
| `iw` / `aw` | Inner/around word |
| `iW` / `aW` | Inner/around WORD (whitespace-delimited) |
| `i"` / `a"` | Inner/around double quotes |
| `i'` / `a'` | Inner/around single quotes |
| `` i` `` / `` a` `` | Inner/around backticks |
| `i(` / `a(` | Inner/around parentheses |
| `i{` / `a{` | Inner/around curly braces |
| `i[` / `a[` | Inner/around square brackets |
| `i<` / `a<` | Inner/around angle brackets |

Examples: `ciw` (change word), `di"` (delete inside quotes), `ya(` (yank around parens).

## Editing

| Key | Action |
|-----|--------|
| `x` | Delete character under cursor |
| `X` | Delete character before cursor |
| `r` + char | Replace character |
| `~` | Toggle case |
| `J` | Join lines |
| `>>` | Indent line |
| `<<` | Outdent line |
| `u` | Undo |
| `Ctrl+r` | Redo |
| `.` | Repeat last action |

## Insert Mode Entry

| Key | Action |
|-----|--------|
| `i` | Insert before cursor |
| `a` | Insert after cursor |
| `I` | Insert at beginning of line |
| `A` | Insert at end of line |
| `o` | Open line below |
| `O` | Open line above |

## Visual Mode

| Key | Action |
|-----|--------|
| `v` | Toggle character-wise visual |
| `V` | Toggle line-wise visual |
| `d` / `c` / `y` | Operate on selection |
| `i`/`a` + object | Select text object |

## Search

| Key | Action |
|-----|--------|
| `/` | Open search bar |
| `Enter` | Search and close bar |
| `n` | Next match |
| `N` | Previous match |

## Clipboard

| Key | Action |
|-----|--------|
| `p` | Paste after cursor (line-aware) |
| `P` | Paste before cursor (line-aware) |

Yank and delete operations copy to the system clipboard.

## Configuration

Exit sequences for insert → normal mode are configured in `keymaps.pkl`:

```pkl
// In keymaps.pkl
keymaps {
  new { action = "exit_insert"; key = "jk"; context = "compose_normal"; sequence = true }
}
```

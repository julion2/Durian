---
title: Shell Completion
weight: 10
---

`durian` ships Cobra-based tab completion for account identifiers (alias,
name, or email) on the commands that take them. It works out of the box with
[carapace](https://carapace.sh) and with the shell-native completion scripts
that Cobra generates.

## What's completable

| Command | Argument |
|---|---|
| `durian auth login <TAB>` | account |
| `durian auth logout <TAB>` | account |
| `durian auth refresh <TAB>` | account |
| `durian sync <TAB>` | first positional (account) |
| `durian send --from <TAB>` | account |
| `durian tag list --account <TAB>` | account |
| `durian draft save --account <TAB>` | account |
| `durian draft save --from <TAB>` | account |
| `durian draft delete --account <TAB>` | account |

Completion reads `config.pkl` and offers the same identifier set that
`durian auth status` shows.

## carapace

If you already use [carapace-bin](https://carapace.sh), you don't need to do
anything extra. carapace's `cobra` bridge auto-discovers the hidden
`durian __complete` subcommand and routes through it.

Sanity check:

```bash
durian __complete auth login ""
# → gmail
#   work
#   personal
#   ...
```

If you maintain a hand-written `~/.config/carapace/specs/durian.yaml`, you
can drop the per-flag definitions and let carapace fall back to the Cobra
bridge instead.

## Native shell completion

Cobra also generates standalone completion scripts. If you don't use
carapace, install the one for your shell:

**bash**

```bash
durian completion bash > ~/.local/share/bash-completion/completions/durian
```

**zsh**

```bash
durian completion zsh > "${fpath[1]}/_durian"
```

(Re-open the shell after the first install, or `compinit` to pick it up.)

**fish**

```bash
durian completion fish > ~/.config/fish/completions/durian.fish
```

**powershell**

```powershell
durian completion powershell | Out-String | Invoke-Expression
```

## nushell

Cobra doesn't generate nushell completion scripts directly, but
[carapace](https://carapace.sh) bridges Cobra's `__complete` to nu out of
the box. The recommended `config.nu` setup is:

```nu
let carapace_completer = {|spans|
  carapace $spans.0 nushell ...$spans | from json
}

$env.config = {
  completions: {
    external: {
      enable: true
      completer: $carapace_completer
    }
  }
}
```

With that block in place, `durian <TAB>` and `durian auth login <TAB>`
work in nu without any extra spec. If you want a hand-written spec instead
(e.g. to constrain completions on flags), drop one into
`~/.config/carapace/specs/durian.yaml` and carapace will prefer it.

## Adding completion for new flags

Account-completable flags are wired up in `cli/cmd/durian/completion.go`. To
add another command:

```go
import "github.com/spf13/cobra"

var cmd = &cobra.Command{
    Use: "...",
    // Positional:
    ValidArgsFunction: completeAccounts,
}

func init() {
    // Flag:
    _ = cmd.RegisterFlagCompletionFunc("from", completeAccounts)
}
```

The `completeAccounts` function reads the current config and returns the
identifier list at completion time, so changes to `config.pkl` are picked up
without rebuilding.

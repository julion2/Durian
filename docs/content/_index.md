---
title: Durian
toc: false
width: wide
---

<div class="hx:text-center hx:mt-10 hx:mb-12">
<img src="logo.png" alt="Durian" width="120" height="120" class="hx:mx-auto hx:mb-6 hx:rounded-2xl" />

{{< hextra/hero-badge >}}Early Alpha{{< /hextra/hero-badge >}}

<div class="hx:mt-6 hx:mb-6">

{{< hextra/hero-headline >}}Durian{{< /hextra/hero-headline >}}

</div>

<div class="hx:mb-12">

{{< hextra/hero-subtitle >}}A native email client with vim-style navigation. Tags instead of folders. Local-first. Pkl-driven.{{< /hextra/hero-subtitle >}}

</div>

<div class="hx:mb-6">

{{< hextra/hero-button text="Get Started" link="docs/getting-started/" >}}&nbsp;&nbsp;<a href="https://github.com/julion2/durian" target="_blank" rel="noreferrer" class="not-prose hx:font-medium hx:cursor-pointer hx:px-6 hx:py-3 hx:rounded-full hx:text-center hx:inline-block hx:border hx:border-gray-300 hx:hover:border-gray-400 hx:text-gray-700 hx:hover:text-gray-900 hx:transition-all hx:duration-200 hx:dark:border-neutral-700 hx:dark:hover:border-neutral-500 hx:dark:text-gray-300 hx:dark:hover:text-gray-100">View on GitHub</a>

</div>

</div>

{{< callout type="warning" >}}
**Early Alpha** — Expect bugs and breaking changes. No external security audit. This is a side project — features and fixes happen as time allows.
{{< /callout >}}

![Durian, light mode](images/screenshot-light.png)

## Features

{{< cards >}}
  {{< card link="docs/getting-started" title="Getting Started" icon="lightning-bolt"
      subtitle="Install, configure your first account, send mail." >}}
  {{< card link="docs/auth" title="Authentication" icon="lock-closed"
      subtitle="OAuth (Gmail, Microsoft 365) or password (everywhere else)." >}}
  {{< card link="docs/keymaps" title="Keymaps" icon="hand"
      subtitle="Vim-style navigation and modal compose editor." >}}
  {{< card link="docs/architecture" title="Architecture" icon="cube-transparent"
      subtitle="How the CLI, GUI, and IMAP sync fit together." >}}
{{< /cards >}}

## What it is

- **Local-first.** All mail lives in a SQLite database. Works offline.
- **Pkl-driven.** Config, rules, and key bindings are typed Pkl, validated at startup.
- **Keyboard-first.** Vim bindings throughout, plus a key-sequence engine for chords.
- **Two parts, one tool.** A `durian` CLI does sync/send/store; the macOS GUI is a thin layer over its HTTP API.

## Install

```bash
brew install pkl                # config language runtime (required)
brew tap julion2/tap
brew install durian             # CLI (required — the GUI uses it as backend)
brew install --cask durian      # GUI (macOS only)
```

Or [build from source](docs/getting-started/#1-install-the-cli).

## More views

### Dark mode

![Durian, dark mode](images/screenshot-dark.png)

### Compose

![Durian compose editor](images/screenshot-compose.png)

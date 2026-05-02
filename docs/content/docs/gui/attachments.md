---
title: Attachments
weight: 5
---

Attachments are listed at the bottom of each message card with filename, size, and an icon based on the file type.

## Preview

| Action | How |
|---|---|
| QuickLook preview | Click the attachment, or press `Space` with it focused |
| Open in default app | Double-click |
| Save | Right-click → **Save As…**, or drag to Finder |

QuickLook uses macOS's built-in preview engine — works for PDFs, images, audio, video, plain text, and any other type with a system QuickLook generator.

## Cached prefetch

When you open a thread, Durian fetches each attachment in the background and stores it in a local cache. Subsequent previews are instant.

Cache settings live in `config.pkl`:

```pkl
sync {
  attachment_cache { max_size_mb = 100; ttl_days = 7 }
}
```

- `max_size_mb` — total cache size (LRU eviction).
- `ttl_days` — discard cached blobs older than this.

The cache is bytes-on-disk only; it never leaves your machine.

## Sending attachments

Drag files into a compose window, or click the paperclip icon. Embedded images (paste from clipboard, drag inline into the body) become inline `cid:` parts; explicit attachments are added as multipart entries.

Total size is shown in the compose toolbar — providers like Gmail reject messages over ~25 MB.

# Password Authentication Setup

For email providers that don't support OAuth (e.g., GMX, web.de, custom SMTP), Durian uses password authentication with macOS Keychain.

## Creating a Keychain Entry

Store your SMTP password securely in macOS Keychain:

```bash
security add-generic-password -s "gmx-smtp" -a "you@gmx.de" -w "your-app-password"
```

- `-s` = service name (used in config.toml as `password_keychain`)
- `-a` = account name (your email address)
- `-w` = password (use an app-specific password if available)

Then add to your config.toml:

```toml
[[accounts]]
name = "GMX"
email = "you@gmx.de"

[accounts.smtp]
host = "mail.gmx.net"
port = 587
auth = "password"
max_attachment_size = "20MB"

[accounts.auth]
username = "you@gmx.de"
password_keychain = "gmx-smtp"
```

## Disabling the Keychain Access Dialog

By default, macOS prompts you to allow access every time `durian` reads from the Keychain. To disable this:

### Option 1: Allow All Applications (Easiest)

1. Open **Keychain Access.app** (Cmd+Space → "Keychain Access")
2. Search for your entry (e.g., "gmx-smtp")
3. Double-click the entry
4. Go to the **Access Control** tab
5. Select **"Allow all applications to access this item"**
6. Click **Save Changes** (enter your Mac password)

### Option 2: Allow Only Durian (More Secure)

1. Open **Keychain Access.app**
2. Search for your entry (e.g., "gmx-smtp")
3. Double-click the entry
4. Go to the **Access Control** tab
5. Keep **"Confirm before allowing access"** selected
6. Click the **+** button under "Always allow access by these applications"
7. Navigate to your durian binary (e.g., `~/.local/bin/durian`)
8. Click **Save Changes**

After this, `durian send` will no longer prompt for Keychain access.

## Common Providers

| Provider | SMTP Host | Port | Notes |
|----------|-----------|------|-------|
| GMX | mail.gmx.net | 587 | Max 20MB attachments |
| web.de | smtp.web.de | 587 | Max 20MB attachments |
| Yahoo | smtp.mail.yahoo.com | 587 | Use app password |
| iCloud | smtp.mail.me.com | 587 | Use app-specific password |
| Fastmail | smtp.fastmail.com | 587 | Use app password |

## Troubleshooting

| Error | Solution |
|-------|----------|
| `keychain entry not found` | Create entry with `security add-generic-password` |
| `failed to get password from keychain` | Check service name matches `password_keychain` in config |
| Repeated access dialogs | Follow "Disabling the Keychain Access Dialog" above |
| `authentication failed` | Verify password is correct, try app-specific password |

## App-Specific Passwords

Many providers require app-specific passwords instead of your main password:

- **GMX/web.de**: Account settings → Security → App passwords
- **Yahoo**: Account security → Generate app password
- **iCloud**: appleid.apple.com → Security → App-Specific Passwords

Using app-specific passwords is more secure and often required when 2FA is enabled.

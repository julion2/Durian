# OAuth Setup

Durian supports OAuth 2.0 for Microsoft 365 and Google/Gmail.

## Microsoft 365

Durian can use a built-in Microsoft OAuth app by default. If you want to use
your own Azure app (recommended for organizations), follow the steps below and
set `client_id` in your config. Otherwise, you can skip app registration and
omit `client_id` (the default will be used).

1. Go to [Azure Portal](https://portal.azure.com) → App registrations → New registration
2. Name: "Durian Mail" (or anything)
3. Supported account types: "Accounts in any organizational directory"
4. Redirect URI: Web → `http://localhost:8080/callback`
5. Go to API Permissions → Add permissions:
   - `offline_access`
   - `https://outlook.office.com/SMTP.Send`
   - `https://outlook.office.com/IMAP.AccessAsUser.All`
6. Grant admin consent (required for work/school accounts)
7. Copy **Application (client) ID**

Add to config.pkl (custom app):
```pkl
oauth {
  provider = "microsoft"
  client_id = "your-client-id"
  // tenant = "common"   // Optional: "common", "organizations", or your tenant ID/domain
}
```

Shared mailboxes: configure the shared mailbox as its own `[[accounts]]` entry
and set `auth_email` to the delegating user who has Full Access + Send As.

## Google

> **Note:** Google OAuth tokens expire every 7 days while the app is in "Testing" mode in Google Cloud Console. You will need to re-authenticate periodically with `durian auth login`. This is a Google limitation for unverified apps (see [#147](https://github.com/julion2/Durian/issues/147)).

1. Go to [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials
2. Create project (if needed)
3. Configure OAuth consent screen (External, add your email as test user)
4. Create credentials → OAuth client ID → Web application
5. Authorized redirect URI: `http://localhost:8080/callback`
6. Copy **Client ID** and **Client Secret**

Add to config.pkl:
```pkl
oauth {
  provider = "google"
  client_id = "your-client-id"
  client_secret = "your-client-secret"
}
```

## Usage

```bash
durian auth login you@company.com   # Opens browser for OAuth (email or alias)
durian auth status                  # Show all accounts + token status
durian auth refresh you@company.com # Manual token refresh
durian auth logout you@company.com  # Remove token from Keychain
```

Tokens are stored securely in macOS Keychain and auto-refresh when near expiry.

## Troubleshooting

| Error | Solution |
|-------|----------|
| `client_secret is missing` | Add `client_secret` to config (required for Google) |
| `redirect_uri_mismatch` | Ensure redirect URI is exactly `http://localhost:8080/callback` |
| `invalid_grant` | Token expired, run `durian auth login` again |
| `AADSTS50011` | Redirect URI not registered in Azure Portal |

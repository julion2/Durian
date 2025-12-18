# OAuth Setup

Durian supports OAuth 2.0 for Microsoft 365 and Google/Gmail.

## Microsoft 365

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

Add to config.toml:
```toml
[accounts.oauth]
provider = "microsoft"
client_id = "your-client-id"
```

## Google

1. Go to [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials
2. Create project (if needed)
3. Configure OAuth consent screen (External, add your email as test user)
4. Create credentials → OAuth client ID → Web application
5. Authorized redirect URI: `http://localhost:8080/callback`
6. Copy **Client ID** and **Client Secret**

Add to config.toml:
```toml
[accounts.oauth]
provider = "google"
client_id = "your-client-id"
client_secret = "your-client-secret"
```

## Usage

```bash
durian auth login you@company.com   # Opens browser for OAuth
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

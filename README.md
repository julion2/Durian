# colonSend

A macOS email client with keyboard shortcuts and auto-refresh capabilities.

## Adding a Mail Account

1. Edit the config file at `~/.config/colonSend/config.json`
2. Add your account details to the accounts array:

```json
{
  "accounts": [
    {
      "name": "Your Name",
      "email": "your.email@example.com",
      "imap": {
        "host": "imap.example.com",
        "port": 993,
        "ssl": true
      },
      "smtp": {
        "host": "smtp.example.com", 
        "port": 587,
        "ssl": false
      },
      "auth": {
        "username": "your.email@example.com",
        "password_keychain": "your-keychain-service-name"
      }
    }
  ]
}
```

3. Store your password in macOS Keychain:
   ```bash
   security add-generic-password -s "your-keychain-service-name" -a "your.email@example.com" -w "your-password"
   ```

4. Restart the app

## Keyboard Shortcuts

Configure shortcuts in `~/.config/colonSend/keymaps.json`. Press Cmd+R to reload keymaps.
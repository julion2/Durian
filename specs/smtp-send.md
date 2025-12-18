# Spec: SMTP Send Feature for Durian CLI

## Context

Durian ist eine Mail-CLI, die aktuell nur Lese-Funktionen bietet (search, show, tag). Das SMTP Send Feature ermöglicht das Versenden von E-Mails über SMTP mit OAuth2-Authentifizierung. Die GUI verwendet bereits ein curl-basiertes SMTP-System mit Username/Password-Auth. Die CLI soll eine robustere Implementierung mit nativer Go-SMTP-Bibliothek und OAuth2-Support bieten.

**Wichtige Designentscheidungen:**
- **KEIN App-Passwort Support** - ausschließlich OAuth2 für Gmail/Microsoft, Username/Password nur für custom SMTP
- OAuth-Token werden in macOS Keychain gespeichert (via `security` CLI)
- Config in `~/.config/durian/config.toml` (analog zur GUI)
- Sent-Mails werden optional in notmuch gespeichert (für Thread-Konsistenz)

## Requirements

### Ubiquitous Requirements

- **REQ-001**: The system shall support sending emails via SMTP with TLS encryption (STARTTLS on port 587 or SSL/TLS on port 465)
- **REQ-002**: The system shall build RFC 5322-compliant MIME messages with proper headers (From, To, Cc, Bcc, Subject, Date, Message-ID, MIME-Version)
- **REQ-003**: The system shall support both plain text and HTML email bodies
- **REQ-004**: The system shall support multiple file attachments with automatic MIME type detection
- **REQ-005**: The system shall encode attachments using base64 encoding
- **REQ-006**: The system shall support multipart/mixed MIME structure for emails with attachments
- **REQ-007**: The system shall read SMTP configuration from `~/.config/durian/config.toml`
- **REQ-008**: The system shall generate unique Message-IDs using format `<uuid@hostname>`
- **REQ-009**: The system shall set the Date header using RFC 5322 format (e.g., "Mon, 02 Jan 2006 15:04:05 -0700")
- **REQ-010**: The system shall support UTF-8 encoding for subject lines and body content
- **REQ-011**: The system shall validate email addresses in To, Cc, and Bcc fields using RFC 5322 syntax

### Event-driven Requirements

- **REQ-100**: When the user invokes `durian send` without flags, the system shall prompt interactively for To, Subject, and Body
- **REQ-101**: When the user provides `--to`, `--cc`, or `--bcc` flags, the system shall accept comma-separated email addresses
- **REQ-102**: When the user provides `--body-file <path>`, the system shall read the email body from the specified file
- **REQ-103**: When the user provides `--attach <path>`, the system shall add the file as an attachment (flag can be repeated for multiple files)
- **REQ-104**: When the user provides `--html` flag, the system shall interpret the body as HTML content
- **REQ-105**: When sending with OAuth2 provider (gmail/microsoft), the system shall retrieve access token from keychain service `durian-oauth-<email>`
- **REQ-106**: When the OAuth2 access token is expired, the system shall attempt to refresh it using the refresh token
- **REQ-107**: When OAuth2 token refresh succeeds, the system shall update the token in keychain
- **REQ-108**: When OAuth2 token refresh fails, the system shall return an authentication error with instructions to re-authenticate
- **REQ-109**: When sending with custom SMTP provider, the system shall retrieve password from keychain service specified in `smtp.custom.password_keychain`
- **REQ-110**: When SMTP connection fails with temporary error (4xx response), the system shall retry up to 3 times with exponential backoff (1s, 2s, 4s)
- **REQ-111**: When email is sent successfully, the system shall optionally save a copy to `~/Mail/Sent/cur/` in maildir format (if `smtp.save_sent = true`)
- **REQ-112**: When a sent email is saved to maildir, the system shall run `notmuch new` to index it
- **REQ-113**: When the user provides `--in-reply-to <message-id>`, the system shall add In-Reply-To and References headers
- **REQ-114**: When an attachment file does not exist, the system shall fail with error before attempting SMTP connection
- **REQ-115**: When the total attachment size exceeds 25MB, the system shall warn the user but allow sending

### State-driven Requirements

- **REQ-200**: While SMTP connection is active, the system shall maintain TLS encryption
- **REQ-201**: While sending is in progress, the system shall display progress information (e.g., "Connecting...", "Authenticating...", "Sending...")
- **REQ-202**: While reading `--body-file`, the system shall preserve line breaks and formatting

### Optional Requirements

- **REQ-300**: Where `smtp.provider = "gmail"`, the system shall use host `smtp.gmail.com` and port `587` with OAuth2 authentication
- **REQ-301**: Where `smtp.provider = "microsoft"`, the system shall use host `smtp.office365.com` and port `587` with OAuth2 authentication
- **REQ-302**: Where `smtp.provider = "custom"`, the system shall use host, port, and auth method from `smtp.custom` section
- **REQ-303**: Where `smtp.save_sent = true`, the system shall save sent emails to maildir
- **REQ-304**: Where `smtp.save_sent = false` or unset, the system shall not save sent emails locally
- **REQ-305**: Where `smtp.custom.auth = "oauth2"`, the system shall use OAuth2 even for custom providers
- **REQ-306**: Where `smtp.custom.auth = "password"`, the system shall use username/password authentication
- **REQ-307**: Where `--from` flag is provided, the system shall use it to override the default sender address from config

### Unwanted Behavior Requirements

- **REQ-400**: If no recipients are specified (no --to, --cc, or --bcc), the system shall fail with error "at least one recipient required"
- **REQ-401**: If SMTP authentication fails, the system shall fail with error message indicating auth failure and provider
- **REQ-402**: If SMTP connection fails (network error, wrong host/port), the system shall fail with descriptive network error
- **REQ-403**: If attachment file cannot be read, the system shall fail with error "failed to read attachment: <filename>"
- **REQ-404**: If config.toml is missing smtp section, the system shall fail with error "SMTP not configured in ~/.config/durian/config.toml"
- **REQ-405**: If keychain access fails, the system shall fail with error "failed to retrieve credentials from keychain"
- **REQ-406**: If SMTP server rejects email (5xx response), the system shall fail immediately without retry
- **REQ-407**: If email address validation fails, the system shall fail with error "invalid email address: <address>"
- **REQ-408**: If both --body and --body-file are provided, the system shall fail with error "cannot use both --body and --body-file"
- **REQ-409**: If the SMTP server does not support STARTTLS when required, the system shall fail with error "TLS required but not supported by server"

## Acceptance Criteria

### Core Sending

- [ ] **AC-001**: Given valid SMTP config and credentials, when user runs `durian send --to "test@example.com" --subject "Test" --body "Hello"`, then email is sent successfully and exit code is 0
- [ ] **AC-002**: Given no flags, when user runs `durian send`, then system prompts for To, Subject, and Body interactively
- [ ] **AC-003**: Given multiple recipients, when user runs `durian send --to "a@ex.com,b@ex.com" --cc "c@ex.com"`, then email is delivered to all three recipients
- [ ] **AC-004**: Given attachment file exists, when user runs `durian send --to "x@ex.com" --subject "Files" --attach file1.pdf --attach file2.jpg`, then email contains both attachments with correct MIME types

### OAuth2 Integration

- [ ] **AC-005**: Given Gmail provider with valid OAuth token in keychain, when user sends email, then system authenticates with OAuth2 XOAUTH2 SASL mechanism
- [ ] **AC-006**: Given expired OAuth token, when user sends email, then system refreshes token automatically
- [ ] **AC-007**: Given failed token refresh, when user sends email, then system exits with error "OAuth token expired, please re-authenticate"
- [ ] **AC-008**: Given Microsoft 365 provider, when user sends email, then system uses smtp.office365.com with OAuth2

### Configuration

- [ ] **AC-009**: Given `smtp.provider = "custom"` with host/port/username/password, when user sends email, then system connects to custom SMTP server
- [ ] **AC-010**: Given `smtp.save_sent = true`, when email is sent, then copy is saved to `~/Mail/Sent/cur/` in maildir format
- [ ] **AC-011**: Given `smtp.save_sent = false`, when email is sent, then no local copy is saved
- [ ] **AC-012**: Given missing smtp config section, when user runs `durian send`, then system exits with error referencing config file

### Error Handling

- [ ] **AC-013**: Given no recipients, when user runs `durian send --subject "Test" --body "Hi"`, then system exits with error "at least one recipient required"
- [ ] **AC-014**: Given wrong SMTP password, when user sends email, then system exits with error "SMTP authentication failed"
- [ ] **AC-015**: Given non-existent attachment, when user runs `durian send --attach missing.pdf`, then system exits with error before connecting to SMTP
- [ ] **AC-016**: Given temporary SMTP error (450), when user sends email, then system retries 3 times with exponential backoff
- [ ] **AC-017**: Given permanent SMTP error (550), when user sends email, then system fails immediately without retry
- [ ] **AC-018**: Given invalid email address "not-an-email", when used in --to, then system exits with error "invalid email address: not-an-email"

### MIME Construction

- [ ] **AC-019**: Given plain text body, when email is sent, then Content-Type is "text/plain; charset=UTF-8"
- [ ] **AC-020**: Given `--html` flag, when email is sent, then Content-Type is "text/html; charset=UTF-8"
- [ ] **AC-021**: Given attachments, when email is sent, then MIME structure is multipart/mixed with proper boundaries
- [ ] **AC-022**: Given UTF-8 characters in subject, when email is sent, then subject is properly encoded (RFC 2047)
- [ ] **AC-023**: Given email sent, when recipient opens it, then Message-ID header is present and unique
- [ ] **AC-024**: Given `--in-reply-to <msg-id>`, when email is sent, then In-Reply-To and References headers are set

### Progress & UX

- [ ] **AC-025**: Given sending in progress, when user waits, then system displays "Connecting...", "Authenticating...", "Sending..." messages
- [ ] **AC-026**: Given successful send, when complete, then system prints "Email sent successfully" and exits 0
- [ ] **AC-027**: Given `--body-file message.txt`, when file contains multiple lines, then all lines and formatting are preserved in email body

## Edge Cases

### Authentication Edge Cases

- **EC-001**: OAuth token exists but is invalid (not just expired) → should fail with "re-authenticate" message, not retry infinitely
- **EC-002**: Keychain access requires user interaction (macOS prompts for password) → system should handle timeout gracefully
- **EC-003**: Multiple accounts in config, no default specified → system should require `--from` flag or fail with clear message
- **EC-004**: Keychain entry exists but is empty/corrupted → should fail with "invalid credentials" not "credentials not found"

### Network Edge Cases

- **EC-005**: SMTP server is reachable but doesn't respond within timeout (30s) → should fail with "connection timeout"
- **EC-006**: SMTP server closes connection mid-send → should fail with "connection lost" error
- **EC-007**: DNS lookup fails for SMTP host → should fail with "cannot resolve host: <host>"
- **EC-008**: IPv6 vs IPv4 connection preference → should try both if available

### MIME Edge Cases

- **EC-009**: Attachment filename contains non-ASCII characters (e.g., "Rechnung_€.pdf") → should encode filename per RFC 2231
- **EC-010**: Email body is empty string → should send email with empty body (valid per RFC 5322)
- **EC-011**: Subject line is empty → should send with "Subject: " header (valid, though warned)
- **EC-012**: Attachment is 0 bytes → should include as valid attachment
- **EC-013**: Body contains only whitespace → should preserve whitespace
- **EC-014**: Extremely long subject line (>998 chars) → should fold header per RFC 5322

### File I/O Edge Cases

- **EC-015**: `--body-file` points to directory not file → should fail with "is a directory" error
- **EC-016**: Attachment file is unreadable due to permissions → should fail with permission error
- **EC-017**: `~/Mail/Sent/cur/` doesn't exist when save_sent=true → should create directory automatically
- **EC-018**: Disk full when saving sent mail → should still report email as sent (SMTP succeeded) but warn about save failure

### Input Validation Edge Cases

- **EC-019**: Email address with display name: `"John Doe" <john@example.com>` → should parse and use correctly
- **EC-020**: Multiple comma-separated emails with spaces: `a@ex.com, b@ex.com , c@ex.com` → should trim spaces
- **EC-021**: Email with + addressing: `user+tag@gmail.com` → should accept as valid
- **EC-022**: International domain: `user@münchen.de` → should handle IDN domains
- **EC-023**: Very long email address (254 chars - RFC limit) → should accept if valid
- **EC-024**: Email with special chars: `"test@test"@example.com` → should accept per RFC 5322 (quoted local-part)

### Config Edge Cases

- **EC-025**: Config file has syntax error → should fail with TOML parse error, not crash
- **EC-026**: Port number is invalid (e.g., 70000) → should fail with validation error
- **EC-027**: Provider is "gmail" but user overrides with custom host → custom host should take precedence
- **EC-028**: `password_keychain` references non-existent keychain entry → should fail with clear error

### Attachment Edge Cases

- **EC-029**: Attachment MIME type detection fails → should fall back to "application/octet-stream"
- **EC-030**: Attachment size is exactly 25MB → should send without warning (warning only >25MB)
- **EC-031**: User attaches same file twice → should include both copies in email
- **EC-032**: Attachment path contains shell metacharacters (spaces, quotes) → should handle correctly
- **EC-033**: Symbolic link as attachment → should follow link and attach target file

### Concurrency Edge Cases

- **EC-034**: User sends multiple emails simultaneously (multiple `durian send` processes) → each should succeed independently
- **EC-035**: OAuth token refresh happens in two processes simultaneously → one should succeed, other should detect fresh token

### Reply/Threading Edge Cases

- **EC-036**: `--in-reply-to` with invalid Message-ID format → should accept and use as-is (server validates)
- **EC-037**: `--in-reply-to` without `--references` → system should derive References from In-Reply-To

## Technical Tasks

### 1. Project Setup & Dependencies (S)
- [ ] Add dependencies to `cli/go.mod`:
  - `github.com/emersion/go-smtp` - SMTP client
  - `github.com/emersion/go-sasl` - SASL auth (XOAUTH2)
  - `golang.org/x/oauth2` - OAuth token refresh
  - `github.com/pelletier/go-toml/v2` - config parsing (if not already present)
- [ ] Create package structure: `cli/internal/smtp/`
- [ ] Implements: REQ-001, REQ-002

### 2. Config Loading (S)
- [ ] Create `cli/internal/config/config.go` with structs for SMTP config
- [ ] Parse `~/.config/durian/config.toml` SMTP section
- [ ] Validate provider ("gmail", "microsoft", "custom")
- [ ] Load custom SMTP settings when provider="custom"
- [ ] Implements: REQ-007, REQ-300, REQ-301, REQ-302
- [ ] Validates: AC-009, AC-012, EC-025, EC-026, EC-027

### 3. Keychain Integration (M)
- [ ] Create `cli/internal/keychain/keychain.go`
- [ ] Implement `GetPassword(service, account) (string, error)` using `security find-generic-password`
- [ ] Implement `SetPassword(service, account, password) error` using `security add-generic-password`
- [ ] Handle keychain user interaction timeout (EC-002)
- [ ] Implements: REQ-105, REQ-109
- [ ] Validates: AC-005, AC-014, EC-002, EC-004

### 4. OAuth2 Token Management (M)
- [ ] Create `cli/internal/oauth/oauth.go`
- [ ] Implement `GetAccessToken(email, provider) (string, error)` - retrieves from keychain
- [ ] Implement `RefreshToken(email, provider, refreshToken) (newAccessToken, error)` - using oauth2 library
- [ ] Store token format in keychain as JSON: `{"access_token": "...", "refresh_token": "...", "expiry": "..."}`
- [ ] Implements: REQ-105, REQ-106, REQ-107, REQ-108
- [ ] Validates: AC-005, AC-006, AC-007, AC-008, EC-001, EC-035

### 5. Email Address Validation (S)
- [ ] Create `cli/internal/mail/validation.go`
- [ ] Implement RFC 5322 email address parser
- [ ] Support display names: `"Name" <email@example.com>`
- [ ] Support quoted local-part, + addressing, IDN domains
- [ ] Trim whitespace from comma-separated lists
- [ ] Implements: REQ-011
- [ ] Validates: AC-018, EC-019, EC-020, EC-021, EC-022, EC-023, EC-024

### 6. MIME Message Builder (M)
- [ ] Create `cli/internal/smtp/mime_builder.go`
- [ ] Implement `BuildMessage(draft) (string, error)`
- [ ] Generate Message-ID: `<uuid@hostname>`
- [ ] Format Date header per RFC 5322
- [ ] Encode subject with RFC 2047 if needed
- [ ] Build plain text message (text/plain; charset=UTF-8)
- [ ] Build HTML message (text/html; charset=UTF-8) when --html flag
- [ ] Build multipart/mixed for attachments
- [ ] Base64-encode attachments with 76-char line wrapping
- [ ] Encode attachment filenames per RFC 2231 if non-ASCII
- [ ] Handle In-Reply-To and References headers
- [ ] Implements: REQ-002, REQ-003, REQ-004, REQ-005, REQ-006, REQ-008, REQ-009, REQ-010
- [ ] Validates: AC-004, AC-019, AC-020, AC-021, AC-022, AC-023, AC-024, EC-009, EC-010, EC-011, EC-012, EC-013, EC-014, EC-036, EC-037

### 7. SMTP Client (L)
- [ ] Create `cli/internal/smtp/client.go`
- [ ] Implement `Send(config, draft) error`
- [ ] Connect via STARTTLS (port 587) or SSL/TLS (port 465)
- [ ] Authenticate with OAuth2 SASL XOAUTH2 (gmail/microsoft)
- [ ] Authenticate with username/password (custom)
- [ ] Send MAIL FROM, RCPT TO (for all To/Cc/Bcc), DATA
- [ ] Retry on 4xx errors (3 retries, exponential backoff 1s, 2s, 4s)
- [ ] Fail immediately on 5xx errors
- [ ] Handle connection timeout (30s), read/write timeouts
- [ ] Implements: REQ-001, REQ-101, REQ-110, REQ-409
- [ ] Validates: AC-001, AC-003, AC-014, AC-016, AC-017, EC-005, EC-006, EC-007, EC-008

### 8. Attachment Handling (M)
- [ ] Create `cli/internal/mail/attachment.go`
- [ ] Implement `LoadAttachment(path) (Attachment, error)`
- [ ] Detect MIME type using `mime.TypeByExtension` or fallback to `application/octet-stream`
- [ ] Read file data, return error if file doesn't exist/unreadable
- [ ] Calculate total attachment size
- [ ] Warn if total size > 25MB (but still allow send)
- [ ] Follow symlinks
- [ ] Handle filenames with special characters
- [ ] Implements: REQ-004, REQ-005, REQ-114, REQ-115
- [ ] Validates: AC-004, AC-015, EC-012, EC-016, EC-029, EC-030, EC-031, EC-032, EC-033

### 9. Sent Mail Saving (M)
- [ ] Create `cli/internal/mail/maildir.go`
- [ ] Implement `SaveToMaildir(email, path) error`
- [ ] Generate unique maildir filename: `<timestamp>.P<pid>.<hostname>,U=<uid>:2,S`
- [ ] Create `~/Mail/Sent/cur/` if doesn't exist
- [ ] Write email to maildir format
- [ ] Run `notmuch new` after save (if notmuch available)
- [ ] Handle disk full error gracefully (warn but don't fail send)
- [ ] Only run if `smtp.save_sent = true`
- [ ] Implements: REQ-111, REQ-112, REQ-303, REQ-304
- [ ] Validates: AC-010, AC-011, EC-017, EC-018

### 10. CLI Command & Flags (M)
- [ ] Create `cli/cmd/durian/send.go`
- [ ] Add `send` subcommand to main CLI
- [ ] Flags: `--to`, `--cc`, `--bcc`, `--subject`, `--body`, `--body-file`, `--attach`, `--html`, `--from`, `--in-reply-to`
- [ ] Interactive mode when no flags (prompt for To, Subject, Body)
- [ ] Validate: no --body + --body-file conflict
- [ ] Validate: at least one recipient
- [ ] Read body from file if --body-file
- [ ] Implements: REQ-100, REQ-101, REQ-102, REQ-103, REQ-104, REQ-113, REQ-202, REQ-307, REQ-400, REQ-408
- [ ] Validates: AC-001, AC-002, AC-003, AC-013, AC-027

### 11. Progress Display (S)
- [ ] Create `cli/internal/smtp/progress.go`
- [ ] Print status messages: "Connecting to SMTP server...", "Authenticating...", "Sending email...", "Email sent successfully"
- [ ] Print to stderr (so stdout can be used for scripting)
- [ ] Implements: REQ-201
- [ ] Validates: AC-025, AC-026

### 12. Error Handling & Messages (M)
- [ ] Create `cli/internal/smtp/errors.go`
- [ ] Define error types: `AuthError`, `NetworkError`, `ConfigError`, `ValidationError`
- [ ] Map SMTP response codes to user-friendly messages
- [ ] Include provider name in auth errors
- [ ] Include filename in file read errors
- [ ] Include config path in config errors
- [ ] Implements: REQ-401, REQ-402, REQ-403, REQ-404, REQ-405, REQ-406, REQ-407
- [ ] Validates: AC-007, AC-012, AC-013, AC-014, AC-015, AC-017, AC-018

### 13. Integration Tests (L)
- [ ] Create `cli/internal/smtp/integration_test.go`
- [ ] Test with mock SMTP server (using go-smtp test server)
- [ ] Test OAuth2 auth flow
- [ ] Test username/password auth
- [ ] Test attachment encoding
- [ ] Test MIME structure
- [ ] Test retry logic
- [ ] Test error scenarios
- [ ] Validates: All ACs

### 14. Documentation (S)
- [ ] Update README with `durian send` usage examples
- [ ] Document config.toml SMTP section structure
- [ ] Document OAuth setup process
- [ ] Add troubleshooting guide

## Example Usage

### Basic Send
```bash
# Interactive
durian send

# With flags
durian send \
  --to "recipient@example.com" \
  --subject "Hello from Durian" \
  --body "This is a test email"
```

### Multiple Recipients
```bash
durian send \
  --to "alice@example.com,bob@example.com" \
  --cc "charlie@example.com" \
  --bcc "archive@company.com" \
  --subject "Team Update" \
  --body-file update.txt
```

### With Attachments
```bash
durian send \
  --to "client@example.com" \
  --subject "Project Proposal" \
  --body "Please find the proposal attached." \
  --attach proposal.pdf \
  --attach budget.xlsx
```

### HTML Email
```bash
durian send \
  --to "newsletter@example.com" \
  --subject "Newsletter" \
  --body-file newsletter.html \
  --html
```

### Reply to Thread
```bash
durian send \
  --to "colleague@example.com" \
  --subject "Re: Meeting Notes" \
  --body "Thanks for sharing!" \
  --in-reply-to "<abc123@example.com>"
```

### Custom From Address
```bash
durian send \
  --from "noreply@company.com" \
  --to "user@example.com" \
  --subject "Automated Report" \
  --body-file report.txt
```

## Config Structure

### Gmail Example
```toml
[smtp]
provider = "gmail"
from = "user@gmail.com"
save_sent = true

# OAuth tokens stored in keychain service "durian-oauth-user@gmail.com"
```

### Microsoft 365 Example
```toml
[smtp]
provider = "microsoft"
from = "user@company.onmicrosoft.com"
save_sent = true

# OAuth tokens stored in keychain service "durian-oauth-user@company.onmicrosoft.com"
```

### Custom SMTP Example (OAuth)
```toml
[smtp]
provider = "custom"
from = "user@custom.com"
save_sent = false

[smtp.custom]
host = "smtp.custom.com"
port = 587
auth = "oauth2"
# OAuth tokens stored in keychain service "durian-oauth-user@custom.com"
```

### Custom SMTP Example (Password)
```toml
[smtp]
provider = "custom"
from = "user@legacy.com"
save_sent = false

[smtp.custom]
host = "mail.legacy.com"
port = 465  # SSL/TLS
auth = "password"
username = "user@legacy.com"
password_keychain = "durian-smtp-legacy"  # keychain service name
```

## Security Considerations

### Credential Storage
- **OAuth tokens** stored in macOS Keychain with service name `durian-oauth-<email>`
- **SMTP passwords** stored in macOS Keychain with custom service name from config
- Never log or print credentials in error messages
- Use `security` CLI tool for keychain access (same as GUI implementation)

### OAuth2 Security
- Access tokens have limited lifetime (typically 1 hour)
- Refresh tokens stored securely in keychain
- Token refresh happens transparently
- Failed refresh requires user re-authentication (prevents infinite retry)

### TLS/SSL
- Enforce TLS for all connections (STARTTLS or SSL/TLS)
- Fail if server doesn't support TLS (REQ-409)
- Validate server certificates (system trust store)

### Input Validation
- Validate all email addresses before SMTP connection
- Validate attachment paths before read
- Validate config before attempting send
- Prevent command injection in file paths

### Error Messages
- Don't leak credentials in error messages
- Don't expose full file paths to untrusted users
- Log detailed errors to stderr, not stdout

## Open Questions

1. **OAuth Setup Flow**: How should users initially authenticate and obtain OAuth tokens? Should `durian send` handle this, or should there be a separate `durian auth` command?
   - **Proposal**: Implement `durian auth gmail|microsoft` command that opens browser for OAuth flow and stores tokens in keychain

2. **Default From Address**: If user has multiple accounts in config, which should be default? Should we require `--from` flag or use first account?
   - **Proposal**: Use first account as default, allow `--from` to override. Print warning if multiple accounts exist.

3. **Sent Folder Location**: Should `~/Mail/Sent/` be configurable, or hardcoded?
   - **Proposal**: Make configurable via `smtp.sent_folder` (default: `~/Mail/Sent/cur/`)

4. **Progress Output**: Should progress messages be controllable via `--quiet` flag?
   - **Proposal**: Add `--quiet` flag to suppress progress, only show errors

5. **Draft Support**: Should there be a way to save drafts before sending?
   - **Proposal**: Out of scope for this spec. Consider separate `durian draft` feature later.

6. **HTML to Plain Text Conversion**: If user sends HTML email, should we auto-generate plain text alternative (multipart/alternative)?
   - **Proposal**: Not in MVP. User can provide both `--body` and `--html` if needed (future enhancement).

7. **BCC Privacy**: Should Bcc addresses be completely hidden from To/Cc recipients (requires separate SMTP DATA commands)?
   - **Proposal**: Yes, send separate DATA for Bcc (standard practice)

8. **Attachment Size Limit**: Should there be a hard limit, or just warning at 25MB?
   - **Proposal**: Warning only. Let SMTP server enforce its own limits.

9. **Concurrent Sends**: Should we prevent multiple sends from same account simultaneously?
   - **Proposal**: No prevention needed. SMTP servers handle concurrency. (EC-034)

10. **notmuch Integration**: Should `notmuch new` be run synchronously (blocking) or asynchronously after send?
    - **Proposal**: Synchronous, but with timeout (5s). Warn if timeout exceeded but don't fail send.

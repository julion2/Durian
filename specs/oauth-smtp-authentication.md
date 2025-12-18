# Spec: OAuth 2.0 SMTP Authentication

## Context
Durian Mail CLI currently uses basic password authentication for SMTP. Modern email providers (Gmail, Microsoft 365) require OAuth 2.0 for secure SMTP access. This spec defines an OAuth implementation that:
- Supports Gmail and Microsoft 365 SMTP authentication
- Stores tokens securely in macOS Keychain
- Automatically refreshes expired access tokens
- Integrates with the existing CLI architecture

## Requirements

### Ubiquitous Requirements

- **REQ-001**: The system shall support OAuth 2.0 authentication for SMTP connections
- **REQ-002**: The system shall store OAuth tokens exclusively in macOS Keychain
- **REQ-003**: The system shall use PKCE (Proof Key for Code Exchange) for all OAuth flows
- **REQ-004**: The system shall never log or persist access tokens, refresh tokens, or client secrets to disk in plaintext
- **REQ-005**: The system shall support Gmail and Microsoft 365 OAuth providers
- **REQ-006**: The CLI shall provide commands for OAuth login, status check, and logout

### Event-Driven Requirements

- **REQ-101**: When a user executes `durian auth login --provider <PROVIDER>`, the system shall initiate an OAuth 2.0 authorization code flow with PKCE
- **REQ-102**: When initiating OAuth flow, the system shall generate a cryptographically secure PKCE code verifier (43-128 characters, URL-safe)
- **REQ-103**: When initiating OAuth flow, the system shall compute the SHA-256 code challenge from the code verifier
- **REQ-104**: When the authorization URL is ready, the system shall open the default browser to the OAuth consent page
- **REQ-105**: When the browser redirects to the callback URL, the system shall capture the authorization code via local HTTP server
- **REQ-106**: When an authorization code is received, the system shall exchange it for access and refresh tokens within 10 minutes
- **REQ-107**: When tokens are obtained, the system shall store them in Keychain with service name `dev.durian.oauth.<provider>` and account name from user's email
- **REQ-108**: When an SMTP connection requires authentication, the system shall check token expiry and refresh if within 5 minutes of expiration
- **REQ-109**: When a refresh token exchange fails with 401/403, the system shall prompt user to re-authenticate
- **REQ-110**: When a user executes `durian auth status`, the system shall display authentication status for all configured providers
- **REQ-111**: When a user executes `durian auth logout --provider <PROVIDER>`, the system shall delete all stored tokens from Keychain

### State-Driven Requirements

- **REQ-201**: While the OAuth callback HTTP server is running, the system shall listen on `localhost:8080` (or next available port 8081-8090)
- **REQ-202**: While waiting for OAuth callback, the system shall display a timeout countdown (default: 5 minutes)
- **REQ-203**: While an access token is valid (not expired), the system shall use it for SMTP authentication without refresh
- **REQ-204**: While a refresh operation is in progress, the system shall block subsequent refresh attempts for the same provider

### Optional Requirements

- **REQ-301**: Where the user has set a custom redirect URI in config, the system shall use it instead of the default `http://localhost:8080/callback`
- **REQ-302**: Where verbose logging is enabled (`--verbose` flag), the system shall log OAuth flow steps (excluding sensitive tokens)
- **REQ-303**: Where the provider is Gmail, the system shall use scope `https://mail.google.com/`
- **REQ-304**: Where the provider is Microsoft, the system shall use scope `https://outlook.office.com/SMTP.Send offline_access`

### Unwanted Behavior Requirements

- **REQ-401**: If no browser is available, the system shall display the authorization URL and instructions for manual code entry
- **REQ-402**: If the callback server fails to start on ports 8080-8090, the system shall abort with error "Unable to start OAuth callback server"
- **REQ-403**: If the OAuth callback is not received within 5 minutes, the system shall timeout and close the callback server
- **REQ-404**: If the authorization code exchange fails, the system shall display the provider's error message and error code
- **REQ-405**: If Keychain access is denied, the system shall abort with error "Keychain access required for secure token storage"
- **REQ-406**: If a token refresh fails due to network error, the system shall retry up to 3 times with exponential backoff (1s, 2s, 4s)
- **REQ-407**: If the provider returns an invalid_grant error during refresh, the system shall delete stored tokens and prompt re-authentication
- **REQ-408**: If SMTP authentication fails with OAuth token, the system shall attempt one token refresh before reporting failure
- **REQ-409**: If the user cancels OAuth in browser (error=access_denied), the system shall exit gracefully with message "Authentication cancelled by user"
- **REQ-410**: If multiple processes attempt concurrent OAuth for same provider, the system shall detect lock and display "Authentication already in progress"

## Acceptance Criteria

### AC-001: Gmail OAuth Flow (Happy Path)
- [ ] Given a user with no Gmail OAuth tokens
- [ ] When user runs `durian auth login --provider gmail`
- [ ] Then browser opens to Google consent page
- [ ] And callback server starts on localhost:8080
- [ ] And after user grants consent, CLI receives authorization code
- [ ] And CLI exchanges code for tokens
- [ ] And tokens are stored in Keychain under service `dev.durian.oauth.gmail`
- [ ] And CLI displays "Successfully authenticated with Gmail"

### AC-002: Microsoft 365 OAuth Flow (Happy Path)
- [ ] Given a user with no Microsoft OAuth tokens
- [ ] When user runs `durian auth login --provider microsoft`
- [ ] Then browser opens to Microsoft consent page with correct scopes
- [ ] And after authorization, tokens are stored in Keychain under service `dev.durian.oauth.microsoft`
- [ ] And CLI displays "Successfully authenticated with Microsoft"

### AC-003: Token Refresh Before Expiry
- [ ] Given valid OAuth tokens stored in Keychain with expiry in 3 minutes
- [ ] When SMTP client requests authentication
- [ ] Then system detects token expiry is imminent (< 5 minutes)
- [ ] And system exchanges refresh token for new access token
- [ ] And new tokens are stored in Keychain
- [ ] And SMTP authentication proceeds with new access token

### AC-004: Token Refresh After Expiry
- [ ] Given expired OAuth tokens in Keychain
- [ ] When SMTP client requests authentication
- [ ] Then system detects token expiry
- [ ] And system exchanges refresh token for new access token
- [ ] And SMTP authentication succeeds

### AC-005: Invalid Refresh Token
- [ ] Given invalid/revoked refresh token in Keychain
- [ ] When system attempts token refresh
- [ ] Then provider returns invalid_grant error
- [ ] And system deletes tokens from Keychain
- [ ] And system displays "Authentication expired. Please run: durian auth login --provider <PROVIDER>"
- [ ] And SMTP operation fails with authentication error

### AC-006: Auth Status Check
- [ ] Given OAuth tokens for Gmail and no tokens for Microsoft
- [ ] When user runs `durian auth status`
- [ ] Then CLI displays:
```
OAuth Status:
  gmail: ✓ Authenticated (expires in 45 minutes)
  microsoft: ✗ Not authenticated
```

### AC-007: Logout
- [ ] Given valid OAuth tokens for Gmail in Keychain
- [ ] When user runs `durian auth logout --provider gmail`
- [ ] Then all tokens are deleted from Keychain
- [ ] And CLI displays "Logged out from Gmail"
- [ ] And subsequent `durian auth status` shows Gmail as not authenticated

### AC-008: OAuth Timeout
- [ ] Given OAuth flow initiated
- [ ] When user does not complete authorization within 5 minutes
- [ ] Then callback server shuts down
- [ ] And CLI displays "Authentication timed out. Please try again."
- [ ] And process exits with code 1

### AC-009: User Cancels in Browser
- [ ] Given browser opened to OAuth consent page
- [ ] When user clicks "Cancel" or "Deny"
- [ ] Then callback receives error=access_denied
- [ ] And CLI displays "Authentication cancelled by user"
- [ ] And process exits with code 0

### AC-010: Network Failure During Token Exchange
- [ ] Given authorization code received
- [ ] When token exchange request fails due to network error
- [ ] Then system retries 3 times with exponential backoff
- [ ] And if all retries fail, displays "Network error during token exchange. Please try again."

### AC-011: PKCE Security Validation
- [ ] Given OAuth flow initiated
- [ ] When code verifier is generated
- [ ] Then verifier length is between 43-128 characters
- [ ] And verifier contains only [A-Z, a-z, 0-9, -, ., _, ~]
- [ ] And code challenge is SHA-256 hash of verifier, base64url-encoded
- [ ] And challenge is sent to OAuth provider with method=S256

### AC-012: Keychain Security
- [ ] Given tokens stored in Keychain
- [ ] When accessing Keychain entries
- [ ] Then service name format is `dev.durian.oauth.<provider>`
- [ ] And account name is user's email address
- [ ] And tokens are stored as secure password items
- [ ] And tokens are not readable by other applications without user consent

### AC-013: Concurrent OAuth Prevention
- [ ] Given OAuth flow in progress for Gmail
- [ ] When another process runs `durian auth login --provider gmail`
- [ ] Then second process detects existing lock file `/tmp/durian-oauth-gmail.lock`
- [ ] And displays "Authentication already in progress for Gmail"
- [ ] And exits with code 1

### AC-014: Port Conflict Handling
- [ ] Given port 8080 is already in use
- [ ] When OAuth callback server starts
- [ ] Then system tries ports 8081, 8082, ..., 8090
- [ ] And if port found, displays "OAuth callback server listening on :<PORT>"
- [ ] And if all ports busy, displays "Unable to start OAuth callback server" and exits

## Edge Cases

### EC-001: No Browser Available
**Scenario:** Running in SSH session without X11 forwarding  
**Behavior:** Display authorization URL and instructions: "Open this URL in a browser: <URL>"  
**Mitigation:** Consider adding `--no-browser` flag for manual flow

### EC-002: Keychain Access Prompt
**Scenario:** First time accessing Keychain, macOS prompts for permission  
**Behavior:** User must click "Allow" in macOS dialog  
**Mitigation:** Display message: "Please allow Keychain access in the dialog"

### EC-003: Token Stored But User Revoked Access Externally
**Scenario:** User revokes app access via Google/Microsoft account settings  
**Behavior:** Next SMTP attempt fails, refresh returns invalid_grant  
**Recovery:** Auto-delete tokens, prompt re-authentication

### EC-004: Clock Skew
**Scenario:** System clock is incorrect, making expiry calculations wrong  
**Behavior:** Token refresh may happen too early or too late  
**Mitigation:** Always attempt refresh on SMTP auth failure

### EC-005: Expired Refresh Token (>180 days unused)
**Scenario:** Refresh token expires due to inactivity  
**Behavior:** Refresh fails with invalid_grant  
**Recovery:** Delete tokens, prompt re-authentication

### EC-006: Multiple Accounts for Same Provider
**Scenario:** User has multiple Gmail accounts  
**Behavior:** Current spec assumes one account per provider  
**Limitation:** Not supported in v1. Future: add `--account <email>` flag

### EC-007: Provider Changes OAuth Endpoints
**Scenario:** Google/Microsoft updates authorization/token URLs  
**Behavior:** Requests fail with 404 or invalid_request  
**Mitigation:** Use well-known discovery endpoints (`.well-known/openid-configuration`)

### EC-008: Callback URL Mismatch
**Scenario:** User configured custom redirect URI but OAuth app expects localhost  
**Behavior:** Provider returns redirect_uri_mismatch error  
**Recovery:** Display clear error with instructions to fix OAuth app configuration

### EC-009: Token Storage During Concurrent SMTP Operations
**Scenario:** Two emails sent simultaneously, both trigger refresh  
**Behavior:** Race condition in Keychain writes  
**Mitigation:** Use file lock during token write operations

### EC-010: Partial Keychain Write Failure
**Scenario:** Access token stored but refresh token fails to store  
**Behavior:** Next refresh fails because refresh token is missing  
**Recovery:** Transaction-like behavior: delete access token if refresh token fails

## Technical Implementation

### Architecture

```
cli/internal/
  oauth/
    provider.go       # OAuth provider interface
    gmail.go          # Gmail-specific OAuth config
    microsoft.go      # Microsoft-specific OAuth config
    pkce.go          # PKCE code generation
    token.go         # Token storage/retrieval
    refresh.go       # Token refresh logic
    server.go        # OAuth callback HTTP server
  smtp/
    auth.go          # SMTP authenticator (uses oauth package)
  keychain/
    keychain.go      # macOS Keychain wrapper
```

### Dependencies

Add to `go.mod`:
```go
require (
    golang.org/x/oauth2 v0.15.0
    github.com/keybase/go-keychain v0.0.0-20231219164618-57a3676c3af6
)
```

### Configuration

OAuth app credentials (hardcoded for "Desktop App" OAuth):

**Gmail:**
```go
ClientID: "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
// No client secret for PKCE public client
Scopes: []string{"https://mail.google.com/"}
AuthURL: "https://accounts.google.com/o/oauth2/v2/auth"
TokenURL: "https://oauth2.googleapis.com/token"
```

**Microsoft:**
```go
ClientID: "YOUR_AZURE_APP_CLIENT_ID"
// No client secret for PKCE public client
Scopes: []string{"https://outlook.office.com/SMTP.Send", "offline_access"}
AuthURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
TokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token"
```

### Token Structure

Stored in Keychain as JSON:
```json
{
  "access_token": "ya29.a0AfH6...",
  "refresh_token": "1//0gL1...",
  "token_type": "Bearer",
  "expiry": "2025-12-18T18:45:00Z"
}
```

### CLI Commands

```bash
# Login commands
durian auth login --provider gmail
durian auth login --provider microsoft
durian auth login --provider gmail --no-browser  # Display URL only

# Status check
durian auth status
durian auth status --provider gmail

# Logout
durian auth logout --provider gmail
durian auth logout --all

# Verbose logging
durian auth login --provider gmail --verbose
```

## Tasks

### Phase 1: Core OAuth Infrastructure (L)
1. [ ] Create `internal/oauth` package structure
2. [ ] Implement PKCE code generation (`pkce.go`)
   - Random 43-128 char verifier
   - SHA-256 challenge generation
   - Base64url encoding
3. [ ] Implement OAuth provider interface (`provider.go`)
   - Interface: `Provider { GetAuthURL(), GetTokenURL(), GetScopes() }`
4. [ ] Implement Gmail provider (`gmail.go`) – REQ-005, REQ-303
5. [ ] Implement Microsoft provider (`microsoft.go`) – REQ-005, REQ-304
6. [ ] **Tests:** Unit tests for PKCE generation, provider configs

### Phase 2: Keychain Integration (M)
7. [ ] Create `internal/keychain` package
8. [ ] Implement Keychain storage (`keychain.go`)
   - Store token JSON
   - Retrieve token JSON
   - Delete token
   - Handle macOS permission dialogs
9. [ ] Implement token struct and serialization (`token.go`)
   - JSON marshal/unmarshal
   - Expiry calculation
   - Implements REQ-002, REQ-007
10. [ ] **Tests:** Keychain storage/retrieval (requires macOS test environment)

### Phase 3: OAuth Callback Server (M)
11. [ ] Implement callback HTTP server (`server.go`)
    - Listen on localhost:8080-8090
    - Handle `/callback` route
    - Extract authorization code or error
    - Return success/error HTML page
    - Timeout after 5 minutes
    - Implements REQ-201, REQ-202, REQ-402, REQ-403
12. [ ] Implement browser launcher
    - Use `exec.Command("open", url)` on macOS
    - Fallback to URL display if command fails
    - Implements REQ-104, REQ-401
13. [ ] **Tests:** Mock HTTP server tests

### Phase 4: OAuth Flow (L)
14. [ ] Implement authorization flow orchestration (`flow.go`)
    - Generate PKCE codes
    - Build auth URL with provider config
    - Start callback server
    - Open browser
    - Wait for callback with timeout
    - Exchange code for tokens
    - Store tokens in Keychain
    - Implements REQ-101-REQ-107
15. [ ] Implement error handling for REQ-404, REQ-409
16. [ ] Implement concurrent OAuth prevention with lock files (REQ-410)
17. [ ] **Tests:** Integration test with mock OAuth server

### Phase 5: Token Refresh (M)
18. [ ] Implement token refresh logic (`refresh.go`)
    - Check token expiry (5-minute buffer)
    - Exchange refresh token
    - Update Keychain
    - Retry logic with exponential backoff
    - Implements REQ-108, REQ-203, REQ-204, REQ-406
19. [ ] Implement invalid token handling (REQ-407, REQ-409)
20. [ ] Implement refresh mutex to prevent concurrent refreshes (REQ-204)
21. [ ] **Tests:** Token refresh scenarios (expired, valid, invalid grant)

### Phase 6: CLI Commands (M)
22. [ ] Implement `durian auth login` command
    - Parse `--provider` flag (gmail/microsoft)
    - Parse `--no-browser` flag
    - Parse `--verbose` flag
    - Call OAuth flow
    - Display success/error
23. [ ] Implement `durian auth status` command
    - List all providers
    - Read tokens from Keychain
    - Display expiry time
    - Implements REQ-110
24. [ ] Implement `durian auth logout` command
    - Parse `--provider` flag
    - Delete tokens from Keychain
    - Display confirmation
    - Implements REQ-111
25. [ ] **Tests:** CLI command integration tests

### Phase 7: SMTP Integration (M)
26. [ ] Create `internal/smtp` package
27. [ ] Implement OAuth SMTP authenticator (`auth.go`)
    - Detect if provider uses OAuth (from config)
    - Retrieve token from Keychain
    - Check expiry, refresh if needed
    - Format SASL XOAUTH2 authentication
    - Implements REQ-001, REQ-408
28. [ ] Update existing SMTP client to use OAuth authenticator
29. [ ] **Tests:** SMTP auth with mocked OAuth tokens

### Phase 8: Documentation & Security Audit (S)
30. [ ] Write OAuth setup guide (`docs/OAUTH_SETUP.md`)
    - How to create Google OAuth app
    - How to create Azure AD app
    - Required redirect URIs
    - Troubleshooting common errors
31. [ ] Security audit checklist:
    - ✓ No tokens logged
    - ✓ PKCE used (no client secret)
    - ✓ Keychain-only storage
    - ✓ HTTPS for OAuth endpoints
    - ✓ Token refresh before expiry
32. [ ] Update main README with OAuth instructions

### Phase 9: End-to-End Testing (M)
33. [ ] Manual test: Gmail OAuth flow on macOS
34. [ ] Manual test: Microsoft OAuth flow on macOS
35. [ ] Manual test: Send email via Gmail with OAuth
36. [ ] Manual test: Send email via Microsoft with OAuth
37. [ ] Manual test: Token refresh after expiry
38. [ ] Manual test: Logout and re-authentication
39. [ ] Manual test: Concurrent authentication prevention

## Security Requirements

### SEC-001: Token Protection
- Access tokens, refresh tokens, and client secrets MUST never appear in:
  - Log files
  - Standard output (unless `--debug-insecure` flag explicitly set)
  - Error messages
  - Core dumps
  - Configuration files in plaintext

### SEC-002: PKCE Enforcement
- All OAuth flows MUST use PKCE with S256 challenge method
- Client secret MUST NOT be embedded in CLI binary
- Use OAuth "public client" application type

### SEC-003: Keychain Security
- Tokens MUST be stored with `kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked`
- Keychain service name MUST follow pattern: `dev.durian.oauth.<provider>`
- Keychain account name MUST be user's email address

### SEC-004: Network Security
- All OAuth endpoints MUST use HTTPS
- Certificate validation MUST NOT be disabled
- Callback server MUST only listen on localhost (127.0.0.1)

### SEC-005: Token Expiry
- Access tokens MUST NOT be used within 5 minutes of expiry
- Expired tokens MUST trigger automatic refresh
- Refresh failures MUST delete stored tokens

### SEC-006: Process Isolation
- OAuth callback server MUST bind to localhost only (not 0.0.0.0)
- Lock files MUST be used to prevent concurrent OAuth flows
- Lock files MUST include process PID for stale lock detection

## Example OAuth Flow

### Successful Gmail Authentication

```bash
$ durian auth login --provider gmail
Starting OAuth authentication for Gmail...
Opening browser for authorization...
OAuth callback server listening on http://localhost:8080

[Browser opens to Google consent page]
[User clicks "Allow"]

✓ Authorization successful
✓ Tokens stored securely in Keychain
✓ Successfully authenticated with Gmail

Your access token will expire in 60 minutes.
```

### Status Check

```bash
$ durian auth status
OAuth Status:
  gmail: ✓ Authenticated
         Account: user@gmail.com
         Expires: 2025-12-18 18:45:00 (in 45 minutes)

  microsoft: ✗ Not authenticated
             Run: durian auth login --provider microsoft
```

### Token Refresh (Automatic, Silent)

```bash
$ durian send --to recipient@example.com --subject "Test"
[OAuth token expires in 3 minutes - auto-refreshing]
✓ Email sent successfully via Gmail SMTP
```

### Logout

```bash
$ durian auth logout --provider gmail
✓ Logged out from Gmail
✓ Tokens removed from Keychain
```

## Open Questions

1. **Client ID Distribution:** Should OAuth client IDs be hardcoded or user-provided?
   - **Option A:** Hardcode Durian's official OAuth apps (requires Durian to register apps)
   - **Option B:** User creates their own OAuth apps (more secure, but complex setup)
   - **Recommendation:** Start with Option B for v1, add official apps in v2

2. **Multiple Accounts:** Should v1 support multiple Gmail/Microsoft accounts?
   - **Current spec:** One account per provider
   - **Future:** Add `--account <email>` flag to support multiple accounts

3. **Token Refresh Background Service:** Should tokens be refreshed proactively by a background daemon?
   - **Current spec:** Refresh on-demand before SMTP operations
   - **Alternative:** Background launchd service refreshes tokens daily
   - **Recommendation:** On-demand for v1 (simpler), background service in v2

4. **Offline Access Scope:** Does Microsoft `offline_access` scope require additional user consent?
   - **Need to verify:** Test if Microsoft prompts extra consent for `offline_access`

5. **SASL Mechanism:** Should we support SASL XOAUTH2 or OAuth Bearer?
   - **Gmail:** Supports XOAUTH2
   - **Microsoft:** Supports XOAUTH2
   - **Recommendation:** XOAUTH2 is standard for SMTP OAuth

## Non-Functional Requirements

### NFR-001: Performance
- OAuth flow completion: < 30 seconds (user interaction not included)
- Token refresh: < 2 seconds
- Keychain access: < 100ms per operation

### NFR-002: Reliability
- Token refresh success rate: > 99.9% (assuming valid refresh token)
- OAuth callback server uptime: 100% during 5-minute auth window

### NFR-003: Usability
- Error messages must be actionable (include next steps)
- Browser auto-open success rate: > 95% on macOS

### NFR-004: Maintainability
- OAuth provider configs must be modular (easy to add new providers)
- Mock providers for testing without real OAuth servers

## Success Metrics

- [ ] OAuth flow completes successfully for Gmail
- [ ] OAuth flow completes successfully for Microsoft 365
- [ ] Tokens stored securely in Keychain (verified by security audit)
- [ ] Access tokens automatically refresh before expiry
- [ ] SMTP emails sent successfully using OAuth tokens
- [ ] Zero plaintext tokens in logs or disk
- [ ] User documentation complete and tested

## References

- [RFC 6749: OAuth 2.0 Framework](https://datatracker.ietf.org/doc/html/rfc6749)
- [RFC 7636: PKCE](https://datatracker.ietf.org/doc/html/rfc7636)
- [Gmail OAuth Guide](https://developers.google.com/identity/protocols/oauth2)
- [Microsoft OAuth Guide](https://learn.microsoft.com/en-us/azure/active-directory/develop/v2-oauth2-auth-code-flow)
- [SASL XOAUTH2](https://developers.google.com/gmail/imap/xoauth2-protocol)

# Spec: Configuration Management System

## Context
Durian Mail CLI currently lacks a configuration system. Configuration is needed for SMTP settings (future), OAuth credentials (future), and general application settings like default sender address and notmuch database path. The configuration will be stored in TOML format at `~/.config/durian/config.toml` with support for XDG Base Directory specification and command-line overrides.

## Requirements

### Ubiquitous Requirements

- **REQ-001**: The system shall store configuration in TOML format
- **REQ-002**: The system shall support multi-level configuration hierarchy (general, notmuch, smtp, oauth sections)
- **REQ-003**: The system shall provide default values for all optional configuration fields
- **REQ-004**: The system shall validate configuration values on load
- **REQ-005**: The system shall make configuration available to all handler and backend components via dependency injection

### Event-driven Requirements

- **REQ-006**: When the application starts, the system shall attempt to load configuration from the determined config path
- **REQ-007**: When no configuration file exists at startup, the system shall create a default configuration file with inline documentation comments
- **REQ-008**: When the `--config` flag is provided, the system shall use the specified path instead of the default location
- **REQ-009**: When `XDG_CONFIG_HOME` is set, the system shall use `$XDG_CONFIG_HOME/durian/config.toml` as the default path
- **REQ-010**: When `XDG_CONFIG_HOME` is not set, the system shall use `~/.config/durian/config.toml` as the default path
- **REQ-011**: When configuration validation fails, the system shall return a descriptive error and exit with non-zero status code
- **REQ-012**: When creating a new configuration file, the system shall create parent directories if they do not exist
- **REQ-013**: When the configuration file is created, the system shall set file permissions to 0600 (read/write for owner only)

### State-driven Requirements

- **REQ-014**: While the application is running, the system shall provide read-only access to configuration values
- **REQ-015**: While processing notmuch operations, the system shall use the configured `database_path` if specified

### Optional Requirements

- **REQ-016**: Where `notmuch.database_path` is not specified, the system shall allow notmuch to use its default database discovery mechanism
- **REQ-017**: Where `general.default_from` is not specified, the system shall accept it as empty (to be required when SMTP feature is implemented)

### Unwanted Behavior Requirements

- **REQ-018**: If the configuration file exists but is not valid TOML, the system shall return a parse error with line number information
- **REQ-019**: If the configuration file exists but cannot be read due to permissions, the system shall return a descriptive permission error
- **REQ-020**: If the configuration file path is a directory, the system shall return an error indicating invalid file type
- **REQ-021**: If email address validation is added in future and `default_from` is invalid, the system shall return a validation error
- **REQ-022**: If the parent directory cannot be created when initializing config, the system shall return a filesystem error
- **REQ-023**: If the configuration contains unknown fields, the system shall log warnings but continue (forward compatibility)

## Configuration Schema

```toml
# Durian Mail Configuration
# This file is automatically created with default values if it doesn't exist.

[general]
# Default email address to use as sender
# Required when sending emails (SMTP feature)
default_from = "user@example.com"

[notmuch]
# Path to notmuch database
# Optional - if not specified, notmuch will use its default discovery:
#   1. $NOTMUCH_DATABASE environment variable
#   2. Database path from notmuch config (~/.notmuch-config)
#   3. $MAILDIR environment variable
# database_path = "~/.mail"

[smtp]
# SMTP settings for sending emails (future feature)
# server = "smtp.example.com"
# port = 587
# use_tls = true
# username = "user@example.com"
# auth_method = "plain"  # plain, login, oauth2

[oauth]
# OAuth2 settings for authentication (future feature)
# provider = "google"  # google, microsoft, custom
# client_id = ""
# client_secret = ""
# redirect_uri = "http://localhost:8080/callback"
# scopes = ["https://mail.google.com/"]
```

## Acceptance Criteria

### Configuration Loading
- **AC-001**: Given no `--config` flag and `XDG_CONFIG_HOME` is not set, when the application starts, then it shall load config from `~/.config/durian/config.toml`
- **AC-002**: Given no `--config` flag and `XDG_CONFIG_HOME=/custom/path`, when the application starts, then it shall load config from `/custom/path/durian/config.toml`
- **AC-003**: Given `--config=/tmp/custom.toml`, when the application starts, then it shall load config from `/tmp/custom.toml`
- **AC-004**: Given a valid config file exists, when the application loads it, then all configured values shall be accessible via the Config struct
- **AC-005**: Given the config file does not exist, when the application starts, then a new config file with default values and comments shall be created

### Configuration Validation
- **AC-006**: Given a config file with invalid TOML syntax, when the application loads it, then it shall exit with error code 1 and display the parse error with line number
- **AC-007**: Given a config file with valid TOML but unsupported sections, when the application loads it, then it shall log warnings but continue execution
- **AC-008**: Given a config file where `general.default_from` is missing, when loaded, then the Config struct shall contain an empty string for default_from

### File System Operations
- **AC-009**: Given the config directory does not exist, when creating a new config file, then the system shall create all parent directories with 0755 permissions
- **AC-010**: Given a new config file is created, when checking file permissions, then the config file shall have 0600 permissions
- **AC-011**: Given the config path points to a directory, when loading config, then it shall return an error "config path is a directory"
- **AC-012**: Given the config file exists but is not readable, when loading config, then it shall return a permission error

### Integration with Existing Code
- **AC-013**: Given config is loaded, when creating a Handler, then the Config shall be passed via dependency injection
- **AC-014**: Given `notmuch.database_path` is configured, when executing notmuch commands, then the `--database` flag shall be passed to notmuch CLI
- **AC-015**: Given `notmuch.database_path` is not configured, when executing notmuch commands, then no `--database` flag shall be passed

### Path Expansion
- **AC-016**: Given `notmuch.database_path = "~/.mail"`, when the config is loaded, then the tilde shall be expanded to the user's home directory
- **AC-017**: Given `notmuch.database_path = "$HOME/.mail"`, when the config is loaded, then the environment variable shall be expanded

## Edge Cases

### File System Edge Cases
- **EC-001**: Config file path is a symbolic link (should follow and read target)
- **EC-002**: Config file is created with race condition (two processes start simultaneously)
- **EC-003**: Config directory path is a symbolic link (should follow and create config inside)
- **EC-004**: Insufficient disk space when creating config file
- **EC-005**: Config file becomes unreadable between path check and read operation (TOCTOU)
- **EC-006**: Config file is on a read-only filesystem
- **EC-007**: Home directory cannot be determined (`os.UserHomeDir()` fails)

### TOML Edge Cases
- **EC-008**: Empty configuration file (valid TOML, no sections)
- **EC-009**: Configuration with only comments
- **EC-010**: Section exists but is empty (e.g., `[general]` with no keys)
- **EC-011**: Duplicate keys in same section (TOML parser behavior)
- **EC-012**: UTF-8 BOM at start of file
- **EC-013**: Very large config file (>1MB)

### Path Handling Edge Cases
- **EC-014**: `XDG_CONFIG_HOME` is set to empty string
- **EC-015**: `XDG_CONFIG_HOME` is set to relative path
- **EC-016**: Config path contains spaces, unicode, or special characters
- **EC-017**: Config path is exactly "/" or "C:\" (root directory)
- **EC-018**: Tilde expansion when user has no home directory
- **EC-019**: Path with multiple consecutive slashes (`//home//user//config.toml`)

### Data Validation Edge Cases
- **EC-020**: Email address in wrong format (handled by future SMTP feature)
- **EC-021**: Negative or zero port numbers in SMTP config (future)
- **EC-022**: Database path points to non-existent directory
- **EC-023**: Database path is empty string vs not specified

### Concurrency Edge Cases
- **EC-024**: Config loaded by multiple goroutines simultaneously
- **EC-025**: Config file modified while application is running (future: hot reload)

### Cross-Platform Edge Cases
- **EC-026**: Windows path handling (`C:\Users\...` vs `/home/...`)
- **EC-027**: Windows `%USERPROFILE%` expansion
- **EC-028**: Case-insensitive filesystems (macOS, Windows)

## Tasks

### Phase 1: Core Configuration Package (M)
1. **[TASK-001]** Create `internal/config` package structure (S) – implements REQ-001, REQ-002
   - Create `config.go` with Config struct matching schema
   - Create `path.go` with path resolution logic
   - Create `config_test.go` with table-driven tests

2. **[TASK-002]** Implement configuration loading (M) – implements REQ-006, REQ-010, REQ-011, REQ-018, REQ-019
   - Add `Load(path string) (*Config, error)` function
   - Use `github.com/BurntSushi/toml` for parsing
   - Implement error handling for parse errors and file I/O
   - Tests: valid config, invalid TOML, missing file, permission errors

3. **[TASK-003]** Implement path resolution (M) – implements REQ-008, REQ-009, REQ-010, REQ-016
   - Add `ResolvePath(customPath string) (string, error)` function
   - Check `--config` flag (customPath parameter)
   - Check `XDG_CONFIG_HOME` environment variable
   - Fallback to `~/.config/durian/config.toml`
   - Implement tilde and environment variable expansion
   - Tests: all path resolution scenarios, AC-001, AC-002, AC-003, EC-014, EC-015, EC-016

4. **[TASK-004]** Implement default config creation (M) – implements REQ-007, REQ-012, REQ-013
   - Add `CreateDefault(path string) error` function
   - Create parent directories with `os.MkdirAll`
   - Write default config with inline comments
   - Set file permissions to 0600
   - Tests: AC-005, AC-009, AC-010, EC-002, EC-004, EC-022

### Phase 2: Validation & Default Values (M)
5. **[TASK-005]** Implement configuration validation (S) – implements REQ-004, REQ-011, REQ-021
   - Add `Validate() error` method on Config struct
   - Validate required fields (currently minimal, expand with SMTP feature)
   - Validate format constraints (paths, email addresses in future)
   - Tests: AC-006, AC-008, EC-020, EC-021

6. **[TASK-006]** Implement default values (S) – implements REQ-003, REQ-016, REQ-017
   - Add `WithDefaults() *Config` method
   - Apply default values for optional fields
   - Tests: ensure defaults applied correctly, AC-008

### Phase 3: Integration with CLI (L)
7. **[TASK-007]** Add `--config` flag to main.go (S) – implements REQ-008
   - Add flag parsing (consider using `flag` or `cobra`)
   - Pass config path to loading function
   - Tests: integration test with flag, AC-003

8. **[TASK-008]** Update main.go to load and use config (M) – implements REQ-005, REQ-014
   - Call config loading at startup
   - Handle "file not found" by creating default config
   - Exit on validation errors with descriptive messages
   - Pass Config to Handler via dependency injection
   - Tests: integration tests, AC-004, AC-006

9. **[TASK-009]** Update Handler to accept Config (S) – implements REQ-005
   - Modify `handler.New()` to accept `*config.Config`
   - Store config in Handler struct
   - Tests: update existing handler tests

### Phase 4: Notmuch Integration (M)
10. **[TASK-010]** Update notmuch Client to support database path (M) – implements REQ-015
    - Modify `notmuch.Client` interface (if needed)
    - Update `ExecClient` to accept optional database path
    - Pass `--database=<path>` flag to notmuch commands when configured
    - Tests: AC-014, AC-015, EC-022

11. **[TASK-011]** Wire config database path to notmuch client (S) – implements REQ-015
    - Pass config.Notmuch.DatabasePath to notmuch client in main.go
    - Handle path expansion
    - Tests: integration test with custom database path

### Phase 5: Error Handling & Edge Cases (M)
12. **[TASK-012]** Implement comprehensive error handling (M) – implements REQ-019, REQ-020, REQ-022
    - Add custom error types for config errors
    - Improve error messages with context
    - Handle all edge cases from EC-001 to EC-028
    - Tests: AC-011, AC-012, all edge cases

13. **[TASK-013]** Add logging for warnings (S) – implements REQ-023
    - Add logging package (consider `log/slog`)
    - Log warnings for unknown config fields
    - Tests: AC-007

### Phase 6: Documentation & Examples (S)
14. **[TASK-014]** Add documentation (S)
    - Add godoc comments to all exported functions
    - Create example config file in `docs/example-config.toml`
    - Update README with configuration section
    - Tests: N/A (documentation task)

15. **[TASK-015]** Add comprehensive tests (L) – validates all AC and EC
    - Create test fixtures for various config scenarios
    - Add integration tests for full startup flow
    - Add cross-platform tests (use build tags)
    - Test coverage > 85%
    - Tests: All AC-001 through AC-017, all edge cases

## Implementation Notes

### Dependency Choice: TOML Parser
**Recommendation**: Use `github.com/BurntSushi/toml`
- **Pros**: Mature, well-tested, good error messages, strict TOML 1.0 compliance
- **Cons**: Slightly more verbose API
- **Alternative**: `github.com/pelletier/go-toml/v2` (faster, simpler API, but less strict)

### Dependency Injection Pattern
```go
// Config struct
type Config struct {
    General GeneralConfig
    Notmuch NotmuchConfig
    SMTP    SMTPConfig
    OAuth   OAuthConfig
}

// Handler accepts config
func handler.New(nm notmuch.Client, cfg *config.Config) *Handler

// Main wires everything
func main() {
    cfg := config.LoadOrCreate()
    nmClient := notmuch.NewExecClient(cfg.Notmuch.DatabasePath)
    h := handler.New(nmClient, cfg)
    // ...
}
```

### Path Expansion Strategy
1. Check for `--config` flag → use as-is (user responsible for correct path)
2. Check `XDG_CONFIG_HOME` → expand if relative, append `/durian/config.toml`
3. Fallback to `~/.config/durian/config.toml`
4. Expand tildes with `filepath.Join(os.UserHomeDir(), ...)`
5. Expand env vars with `os.ExpandEnv()`
6. Clean path with `filepath.Clean()`

### File Permission Rationale
- **Config file: 0600** – May contain sensitive credentials (OAuth tokens, SMTP passwords)
- **Config directory: 0755** – Standard directory permissions, no sensitive data in directory itself

### Error Handling Pattern
```go
// Custom error types
type ConfigError struct {
    Path string
    Err  error
}

func (e *ConfigError) Error() string {
    return fmt.Sprintf("config error at %s: %v", e.Path, e.Err)
}

// Wrapped errors for better context
if err != nil {
    return nil, &ConfigError{Path: path, Err: err}
}
```

### Testing Strategy
- **Unit tests**: Each function in isolation with mocked filesystem
- **Integration tests**: Full startup flow with real files in temp directory
- **Table-driven tests**: All path resolution scenarios, validation rules
- **Error tests**: All error conditions and edge cases
- **Cross-platform tests**: Use `//go:build` tags for OS-specific tests

## Open Questions

1. **Q1**: Should the application support runtime config reload (hot reload)?
   - **Impact**: Would require file watching and thread-safe config updates
   - **Recommendation**: Defer to future feature; current spec uses read-only config loaded at startup

2. **Q2**: Should unknown TOML fields cause errors or warnings?
   - **Impact**: Forward/backward compatibility with future config versions
   - **Recommendation**: Warnings only (REQ-023) for better upgrade experience

3. **Q3**: Should we validate that `notmuch.database_path` exists and is a valid notmuch database?
   - **Impact**: Early error detection vs allowing notmuch to handle errors
   - **Recommendation**: No validation; let notmuch report errors for better error messages

4. **Q4**: Should we support multiple config files (e.g., global + user + local)?
   - **Impact**: Complexity in merging configs and determining precedence
   - **Recommendation**: Single config file for MVP; can add later if needed

5. **Q5**: Should SMTP passwords be stored in config or use OS keychain?
   - **Impact**: Security vs simplicity
   - **Recommendation**: Defer to SMTP feature spec; config should support both approaches

6. **Q6**: Should we support `.env` files or only TOML?
   - **Impact**: Additional parsing complexity vs developer convenience
   - **Recommendation**: TOML only; environment variables can override via expansion

7. **Q7**: Should `--config` flag support `-` for reading from stdin?
   - **Impact**: Useful for testing and containerized deployments
   - **Recommendation**: Nice-to-have; not required for MVP

8. **Q8**: Should we add a `durian config validate` command?
   - **Impact**: Better UX for config debugging
   - **Recommendation**: Add in Phase 6 if time permits; not blocking

## Dependencies

### External Go Packages
- `github.com/BurntSushi/toml` – TOML parsing (add to go.mod)
- `log/slog` (stdlib) – Structured logging for warnings

### Internal Dependencies
- Modifies: `cli/cmd/durian/main.go`
- Modifies: `cli/internal/handler/handler.go`
- Modifies: `cli/internal/backend/notmuch/client.go`
- Creates: `cli/internal/config/` (new package)

### System Dependencies
- Notmuch CLI (existing requirement)
- POSIX-compliant filesystem for permissions

## Success Metrics

- ✅ All 17 acceptance criteria pass
- ✅ All 28 edge cases handled
- ✅ Test coverage ≥ 85%
- ✅ Zero panics on invalid config input
- ✅ Config file created automatically on first run
- ✅ Existing functionality (search, show, tag) continues to work with config system
- ✅ Config loading adds < 10ms to startup time

## Future Enhancements (Out of Scope for This Spec)

- Hot reload / config file watching
- `durian config` subcommand with `get`, `set`, `validate` operations
- Config migration system for version upgrades
- Multiple profile support (work/personal email accounts)
- Encrypted config sections for sensitive data
- Config schema validation with JSON Schema or similar
- Integration with OS credential managers (macOS Keychain, GNOME Keyring, Windows Credential Manager)

---

**Estimated Complexity**: Medium-Large (15 tasks, ~3-5 days of development)

**Risk Level**: Low
- Well-defined scope
- Minimal external dependencies
- No breaking changes to existing functionality
- Standard patterns in Go ecosystem

**Blocked By**: None

**Blocks**: SMTP implementation, OAuth implementation

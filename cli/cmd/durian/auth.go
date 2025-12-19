package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/keychain"
	"github.com/durian-dev/durian/cli/internal/oauth"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

const (
	// PasswordKeychainService is the service name for password-based auth
	PasswordKeychainService = "durian-password"
)

var authCmd = &cobra.Command{
	Use:   "auth",
	Short: "Manage authentication for email accounts",
	Long:  `Manage authentication (OAuth or password) for email accounts.`,
}

var authLoginCmd = &cobra.Command{
	Use:   "login <email>",
	Short: "Authenticate with an email account",
	Long: `Authenticate with an email account using OAuth or password.

For OAuth accounts (Gmail, Microsoft 365):
  Opens your browser to complete the authentication.

For password accounts:
  Prompts for your password and stores it securely in Keychain.

The account must be configured in your config.toml.`,
	Example: `  durian auth login julian@habric.com     # OAuth (Microsoft)
  durian auth login julianschenker05@gmail.com  # OAuth (Google)
  durian auth login julian.schenker@gmx.de      # Password`,
	Args: cobra.ExactArgs(1),
	RunE: runAuthLogin,
}

var authStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show authentication status for all accounts",
	Long:  `Display the authentication status for all configured accounts.`,
	RunE:  runAuthStatus,
}

var authLogoutCmd = &cobra.Command{
	Use:   "logout <email>",
	Short: "Remove credentials for an account",
	Long:  `Remove stored OAuth tokens or passwords from the keychain.`,
	Args:  cobra.ExactArgs(1),
	RunE:  runAuthLogout,
}

var authRefreshCmd = &cobra.Command{
	Use:   "refresh <email>",
	Short: "Manually refresh OAuth token for an account",
	Long:  `Force a token refresh for the specified account. This is normally done automatically.`,
	Args:  cobra.ExactArgs(1),
	RunE:  runAuthRefresh,
}

func init() {
	rootCmd.AddCommand(authCmd)
	authCmd.AddCommand(authLoginCmd)
	authCmd.AddCommand(authStatusCmd)
	authCmd.AddCommand(authLogoutCmd)
	authCmd.AddCommand(authRefreshCmd)
}

func runAuthLogin(cmd *cobra.Command, args []string) error {
	email := args[0]

	// Get config
	cfg := GetConfig()
	if cfg == nil {
		return errors.New("no configuration loaded")
	}

	// Find account by email
	account, err := cfg.GetAccountByEmail(email)
	if err != nil {
		return fmt.Errorf("account not found: %s\nMake sure it's configured in your config.toml", email)
	}

	// Determine auth type: OAuth or Password
	if account.OAuth.Provider != "" {
		return runOAuthLogin(account)
	}

	// Check if password auth is configured
	if account.SMTP.Auth == "password" || account.IMAP.Auth == "password" {
		return runPasswordLogin(account)
	}

	return fmt.Errorf("no authentication method configured for %s\nAdd [accounts.oauth] or set auth = \"password\" in config.toml", email)
}

// runOAuthLogin handles OAuth authentication
func runOAuthLogin(account *config.AccountConfig) error {
	if account.OAuth.ClientID == "" {
		return fmt.Errorf("no client_id configured for %s\nAdd client_id to [accounts.oauth] in your config.toml", account.Email)
	}

	// Get provider
	provider, err := oauth.GetProvider(account.OAuth.Provider, account.OAuth.Tenant)
	if err != nil {
		return err
	}

	// Check if Google requires client_secret
	if account.OAuth.Provider == "google" && account.OAuth.ClientSecret == "" {
		return fmt.Errorf("Google OAuth requires client_secret\nAdd client_secret to [accounts.oauth] in your config.toml")
	}

	fmt.Printf("Starting OAuth authentication for %s (%s)...\n\n", account.Email, account.OAuth.Provider)

	// Run OAuth flow
	token, err := oauth.Authenticate(provider, account.OAuth.ClientID, account.OAuth.ClientSecret, account.Email)
	if err != nil {
		return fmt.Errorf("authentication failed: %w", err)
	}

	// Save token to keychain
	if err := oauth.SaveToken(account.Email, token); err != nil {
		return fmt.Errorf("failed to save token: %w", err)
	}

	fmt.Printf("\n✓ Successfully authenticated with %s\n", account.OAuth.Provider)
	fmt.Printf("✓ Token stored securely in Keychain\n")
	fmt.Printf("✓ Token expires in %s\n", formatDuration(token.ExpiresIn()))

	return nil
}

// runPasswordLogin handles password-based authentication
func runPasswordLogin(account *config.AccountConfig) error {
	fmt.Printf("Password authentication for %s\n\n", account.Email)

	// Prompt for password
	password, err := promptPassword("Enter password: ")
	if err != nil {
		return fmt.Errorf("failed to read password: %w", err)
	}

	if password == "" {
		return errors.New("password cannot be empty")
	}

	// Store password in keychain
	if err := keychain.SetPassword(PasswordKeychainService, account.Email, password); err != nil {
		return fmt.Errorf("failed to save password: %w", err)
	}

	fmt.Printf("\n✓ Password stored securely in Keychain\n")
	fmt.Printf("✓ Service: %s\n", PasswordKeychainService)
	fmt.Printf("✓ Account: %s\n", account.Email)

	return nil
}

// promptPassword securely prompts for a password (hides input)
func promptPassword(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)

	// Check if stdin is a terminal
	if term.IsTerminal(int(os.Stdin.Fd())) {
		// Read password without echo
		password, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr) // Print newline after password input
		if err != nil {
			return "", err
		}
		return string(password), nil
	}

	// Fallback for non-terminal (e.g., piped input)
	reader := bufio.NewReader(os.Stdin)
	password, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(password), nil
}

func runAuthStatus(cmd *cobra.Command, args []string) error {
	cfg := GetConfig()
	if cfg == nil {
		return errors.New("no configuration loaded")
	}

	if len(cfg.Accounts) == 0 {
		fmt.Println("No accounts configured.")
		return nil
	}

	fmt.Println("Authentication Status:")
	fmt.Println()

	for _, account := range cfg.Accounts {
		status := getAccountStatus(&account)
		fmt.Printf("  %-30s  %-12s  %s\n", account.Email, getAuthType(&account), status)
	}

	return nil
}

func runAuthLogout(cmd *cobra.Command, args []string) error {
	email := args[0]

	cfg := GetConfig()
	if cfg == nil {
		return errors.New("no configuration loaded")
	}

	// Find account to determine auth type
	account, err := cfg.GetAccountByEmail(email)
	if err != nil {
		// Account not in config, try to delete both types
		oauthDeleted := oauth.DeleteToken(email) == nil && keychain.Exists(oauth.KeychainService, email)
		pwDeleted := keychain.DeletePassword(PasswordKeychainService, email) == nil && keychain.Exists(PasswordKeychainService, email)

		if !oauthDeleted && !pwDeleted {
			fmt.Printf("No credentials found for %s\n", email)
			return nil
		}
	} else {
		// Delete based on account type
		if account.OAuth.Provider != "" {
			// OAuth account
			_, err := oauth.LoadToken(email)
			if err != nil {
				if errors.Is(err, oauth.ErrTokenNotFound) {
					fmt.Printf("No token found for %s\n", email)
					return nil
				}
				return err
			}

			if err := oauth.DeleteToken(email); err != nil {
				return fmt.Errorf("failed to delete token: %w", err)
			}
		} else {
			// Password account
			if !keychain.Exists(PasswordKeychainService, email) {
				fmt.Printf("No password found for %s\n", email)
				return nil
			}

			if err := keychain.DeletePassword(PasswordKeychainService, email); err != nil {
				return fmt.Errorf("failed to delete password: %w", err)
			}
		}
	}

	fmt.Printf("✓ Logged out from %s\n", email)
	fmt.Printf("✓ Credentials removed from Keychain\n")

	return nil
}

func runAuthRefresh(cmd *cobra.Command, args []string) error {
	email := args[0]

	cfg := GetConfig()
	if cfg == nil {
		return errors.New("no configuration loaded")
	}

	// Find account
	account, err := cfg.GetAccountByEmail(email)
	if err != nil {
		return fmt.Errorf("account not found: %s", email)
	}

	// Only OAuth accounts can be refreshed
	if account.OAuth.Provider == "" {
		return fmt.Errorf("%s uses password authentication (no refresh needed)", email)
	}

	if account.OAuth.ClientID == "" {
		return fmt.Errorf("no OAuth configuration for %s", email)
	}

	// Load existing token
	token, err := oauth.LoadToken(email)
	if err != nil {
		if errors.Is(err, oauth.ErrTokenNotFound) {
			return fmt.Errorf("no token found for %s\nRun: durian auth login %s", email, email)
		}
		return err
	}

	// Get provider
	provider, err := oauth.GetProvider(token.Provider, account.OAuth.Tenant)
	if err != nil {
		return err
	}

	fmt.Printf("Refreshing token for %s...\n", email)

	// Refresh token
	newToken, err := oauth.RefreshAccessToken(provider, account.OAuth.ClientID, account.OAuth.ClientSecret, token)
	if err != nil {
		if errors.Is(err, oauth.ErrTokenExpired) {
			// Delete invalid token
			_ = oauth.DeleteToken(email)
			return fmt.Errorf("refresh token expired\nRun: durian auth login %s", email)
		}
		return fmt.Errorf("refresh failed: %w", err)
	}

	// Save new token
	if err := oauth.SaveToken(email, newToken); err != nil {
		return fmt.Errorf("failed to save token: %w", err)
	}

	fmt.Printf("✓ Token refreshed successfully\n")
	fmt.Printf("✓ New token expires in %s\n", formatDuration(newToken.ExpiresIn()))

	return nil
}

func getAccountStatus(account *config.AccountConfig) string {
	// Check OAuth accounts
	if account.OAuth.Provider != "" {
		token, err := oauth.LoadToken(account.Email)
		if err != nil {
			if errors.Is(err, oauth.ErrTokenNotFound) {
				return fmt.Sprintf("✗ Not authenticated\n%34sRun: durian auth login %s", "", account.Email)
			}
			return fmt.Sprintf("✗ Error: %v", err)
		}

		if token.IsExpired() {
			return "⚠ Expired (will refresh on next use)"
		}

		expiresIn := token.ExpiresIn()
		if expiresIn < 5*time.Minute {
			return fmt.Sprintf("⚠ Expiring soon (%s)", formatDuration(expiresIn))
		}

		return fmt.Sprintf("✓ Valid (expires in %s)", formatDuration(expiresIn))
	}

	// Check password accounts
	if account.SMTP.Auth == "password" || account.IMAP.Auth == "password" {
		if keychain.Exists(PasswordKeychainService, account.Email) {
			return "✓ Password stored"
		}
		return fmt.Sprintf("✗ No password\n%34sRun: durian auth login %s", "", account.Email)
	}

	return "— (no auth configured)"
}

func getAuthType(account *config.AccountConfig) string {
	if account.OAuth.Provider != "" {
		return account.OAuth.Provider
	}
	if account.SMTP.Auth == "password" || account.IMAP.Auth == "password" {
		return "password"
	}
	return "—"
}

func formatDuration(d time.Duration) string {
	if d < 0 {
		return "expired"
	}

	hours := int(d.Hours())
	minutes := int(d.Minutes()) % 60

	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, minutes)
	}
	return fmt.Sprintf("%dm", minutes)
}

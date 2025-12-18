package main

import (
	"errors"
	"fmt"
	"time"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/oauth"
	"github.com/spf13/cobra"
)

var authCmd = &cobra.Command{
	Use:   "auth",
	Short: "Manage OAuth authentication for email accounts",
	Long:  `Manage OAuth 2.0 authentication tokens for Gmail and Microsoft 365 accounts.`,
}

var authLoginCmd = &cobra.Command{
	Use:   "login <email>",
	Short: "Authenticate with an email account via OAuth",
	Long: `Start the OAuth 2.0 authorization flow for an email account.
This will open your browser to complete the authentication.

The account must be configured in your config.toml with OAuth settings:

  [[accounts]]
  name = "Work"
  email = "you@company.com"
  
  [accounts.smtp]
  auth = "oauth2"
  
  [accounts.oauth]
  provider = "microsoft"
  client_id = "your-azure-app-client-id"`,
	Args: cobra.ExactArgs(1),
	RunE: runAuthLogin,
}

var authStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show authentication status for all accounts",
	Long:  `Display the OAuth authentication status for all configured accounts.`,
	RunE:  runAuthStatus,
}

var authLogoutCmd = &cobra.Command{
	Use:   "logout <email>",
	Short: "Remove OAuth tokens for an account",
	Long:  `Remove stored OAuth tokens from the keychain for the specified account.`,
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

	// Check if OAuth is configured
	if account.OAuth.Provider == "" {
		return fmt.Errorf("no OAuth provider configured for %s\nAdd [accounts.oauth] section to your config.toml", email)
	}

	if account.OAuth.ClientID == "" {
		return fmt.Errorf("no client_id configured for %s\nAdd client_id to [accounts.oauth] in your config.toml", email)
	}

	// Get provider
	provider, err := oauth.GetProvider(account.OAuth.Provider, account.OAuth.Tenant)
	if err != nil {
		return err
	}

	fmt.Printf("Starting OAuth authentication for %s (%s)...\n\n", email, account.OAuth.Provider)

	// Run OAuth flow
	token, err := oauth.Authenticate(provider, account.OAuth.ClientID, email)
	if err != nil {
		return fmt.Errorf("authentication failed: %w", err)
	}

	// Save token to keychain
	if err := oauth.SaveToken(email, token); err != nil {
		return fmt.Errorf("failed to save token: %w", err)
	}

	fmt.Printf("\n✓ Successfully authenticated with %s\n", account.OAuth.Provider)
	fmt.Printf("✓ Token stored securely in Keychain\n")
	fmt.Printf("✓ Token expires in %s\n", formatDuration(token.ExpiresIn()))

	return nil
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

	fmt.Println("OAuth Status:")
	fmt.Println()

	for _, account := range cfg.Accounts {
		status := getAccountStatus(&account)
		fmt.Printf("  %-30s  %-12s  %s\n", account.Email, getProviderName(&account), status)
	}

	return nil
}

func runAuthLogout(cmd *cobra.Command, args []string) error {
	email := args[0]

	// Check if token exists
	_, err := oauth.LoadToken(email)
	if err != nil {
		if errors.Is(err, oauth.ErrTokenNotFound) {
			fmt.Printf("No token found for %s\n", email)
			return nil
		}
		return err
	}

	// Delete token
	if err := oauth.DeleteToken(email); err != nil {
		return fmt.Errorf("failed to delete token: %w", err)
	}

	fmt.Printf("✓ Logged out from %s\n", email)
	fmt.Printf("✓ Token removed from Keychain\n")

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
	newToken, err := oauth.RefreshAccessToken(provider, account.OAuth.ClientID, token)
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
	// Check if using password auth
	if account.SMTP.Auth == "password" || account.OAuth.Provider == "" {
		return "— (password auth)"
	}

	// Try to load token
	token, err := oauth.LoadToken(account.Email)
	if err != nil {
		if errors.Is(err, oauth.ErrTokenNotFound) {
			return fmt.Sprintf("✗ Not authenticated\n%34sRun: durian auth login %s", "", account.Email)
		}
		return fmt.Sprintf("✗ Error: %v", err)
	}

	// Check expiry
	if token.IsExpired() {
		return "⚠ Expired (will refresh on next use)"
	}

	expiresIn := token.ExpiresIn()
	if expiresIn < 5*time.Minute {
		return fmt.Sprintf("⚠ Expiring soon (%s)", formatDuration(expiresIn))
	}

	return fmt.Sprintf("✓ Valid (expires in %s)", formatDuration(expiresIn))
}

func getProviderName(account *config.AccountConfig) string {
	if account.OAuth.Provider != "" {
		return account.OAuth.Provider
	}
	if account.SMTP.Auth == "password" {
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

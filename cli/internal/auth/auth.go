// Package auth provides shared authentication helpers for SMTP sending.
package auth

import (
	"errors"
	"fmt"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/keychain"
	"github.com/durian-dev/durian/cli/internal/oauth"
	"github.com/durian-dev/durian/cli/internal/smtp"
)

const (
	// PasswordKeychainService is the service name for password-based auth.
	PasswordKeychainService = "durian-password"
)

// GetSMTPAuth returns the appropriate SMTP auth method for the given account.
func GetSMTPAuth(account *config.AccountConfig) (smtp.Auth, error) {
	switch account.SMTP.Auth {
	case "oauth2":
		if account.OAuth.Provider == "" {
			return nil, fmt.Errorf("OAuth provider not configured for %s", account.Email)
		}

		token, err := oauth.GetValidToken(account.Email, account.OAuth.ClientID, account.OAuth.ClientSecret, account.OAuth.Tenant)
		if err != nil {
			if errors.Is(err, oauth.ErrTokenNotFound) {
				return nil, fmt.Errorf("not authenticated for %s", account.Email)
			}
			if errors.Is(err, oauth.ErrTokenExpired) {
				return nil, fmt.Errorf("authentication expired for %s", account.Email)
			}
			return nil, fmt.Errorf("failed to get OAuth token: %w", err)
		}

		return &smtp.OAuth2Auth{
			Email:       account.Email,
			AccessToken: token.AccessToken,
		}, nil

	case "password":
		password, err := keychain.GetPassword(PasswordKeychainService, account.Email)
		if err != nil {
			if errors.Is(err, keychain.ErrNotFound) {
				return nil, fmt.Errorf("no password stored for %s", account.Email)
			}
			return nil, fmt.Errorf("failed to get password from keychain: %w", err)
		}

		username := account.Auth.Username
		if username == "" {
			username = account.Email
		}

		return &smtp.PasswordAuth{
			Username: username,
			Password: password,
		}, nil

	default:
		return nil, fmt.Errorf("unsupported auth method: %s", account.SMTP.Auth)
	}
}

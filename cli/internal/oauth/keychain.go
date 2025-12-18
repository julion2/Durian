package oauth

import (
	"encoding/json"
	"fmt"

	"github.com/keybase/go-keychain"
)

const (
	// KeychainService is the service name used for storing OAuth tokens
	KeychainService = "durian-oauth"
)

// SaveToken stores an OAuth token in the macOS Keychain
func SaveToken(email string, token *Token) error {
	data, err := json.Marshal(token)
	if err != nil {
		return fmt.Errorf("failed to marshal token: %w", err)
	}

	// First try to delete any existing item
	_ = DeleteToken(email)

	// Create new keychain item
	item := keychain.NewItem()
	item.SetSecClass(keychain.SecClassGenericPassword)
	item.SetService(KeychainService)
	item.SetAccount(email)
	item.SetData(data)
	item.SetSynchronizable(keychain.SynchronizableNo)
	item.SetAccessible(keychain.AccessibleWhenUnlocked)

	if err := keychain.AddItem(item); err != nil {
		return fmt.Errorf("failed to save token to keychain: %w", err)
	}

	return nil
}

// LoadToken retrieves an OAuth token from the macOS Keychain
func LoadToken(email string) (*Token, error) {
	query := keychain.NewItem()
	query.SetSecClass(keychain.SecClassGenericPassword)
	query.SetService(KeychainService)
	query.SetAccount(email)
	query.SetMatchLimit(keychain.MatchLimitOne)
	query.SetReturnData(true)

	results, err := keychain.QueryItem(query)
	if err != nil {
		return nil, fmt.Errorf("failed to query keychain: %w", err)
	}

	if len(results) == 0 {
		return nil, ErrTokenNotFound
	}

	var token Token
	if err := json.Unmarshal(results[0].Data, &token); err != nil {
		return nil, fmt.Errorf("failed to unmarshal token: %w", err)
	}

	return &token, nil
}

// DeleteToken removes an OAuth token from the macOS Keychain
func DeleteToken(email string) error {
	item := keychain.NewItem()
	item.SetSecClass(keychain.SecClassGenericPassword)
	item.SetService(KeychainService)
	item.SetAccount(email)

	if err := keychain.DeleteItem(item); err != nil {
		if err == keychain.ErrorItemNotFound {
			return nil // Not an error if item doesn't exist
		}
		return fmt.Errorf("failed to delete token from keychain: %w", err)
	}

	return nil
}

// ListTokenAccounts returns all email addresses that have stored tokens
func ListTokenAccounts() ([]string, error) {
	query := keychain.NewItem()
	query.SetSecClass(keychain.SecClassGenericPassword)
	query.SetService(KeychainService)
	query.SetMatchLimit(keychain.MatchLimitAll)
	query.SetReturnAttributes(true)

	results, err := keychain.QueryItem(query)
	if err != nil {
		if err == keychain.ErrorItemNotFound {
			return []string{}, nil
		}
		return nil, fmt.Errorf("failed to list keychain items: %w", err)
	}

	accounts := make([]string, 0, len(results))
	for _, item := range results {
		if item.Account != "" {
			accounts = append(accounts, item.Account)
		}
	}

	return accounts, nil
}

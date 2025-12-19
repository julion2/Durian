// Package keychain provides a wrapper around the macOS security CLI
// for storing and retrieving credentials from the system Keychain.
//
// This approach is used instead of direct Keychain API access (via CGo)
// because it allows the user to grant "Always Allow" permission to
// /usr/bin/security once, eliminating repeated password prompts.
package keychain

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

var (
	// ErrNotFound is returned when a keychain item doesn't exist
	ErrNotFound = errors.New("keychain item not found")
)

// GetPassword retrieves a password from the macOS Keychain
func GetPassword(service, account string) (string, error) {
	cmd := exec.Command("security", "find-generic-password",
		"-s", service,
		"-a", account,
		"-w", // Output only the password
	)

	output, err := cmd.Output()
	if err != nil {
		// Check if it's a "not found" error
		if exitErr, ok := err.(*exec.ExitError); ok {
			// Exit code 44 = item not found
			if exitErr.ExitCode() == 44 {
				return "", ErrNotFound
			}
			// Include stderr in error message
			return "", fmt.Errorf("keychain error: %s", string(exitErr.Stderr))
		}
		return "", fmt.Errorf("failed to get password: %w", err)
	}

	return strings.TrimSpace(string(output)), nil
}

// SetPassword stores a password in the macOS Keychain
// If the item already exists, it will be updated
func SetPassword(service, account, password string) error {
	// First try to delete any existing item (ignore errors)
	_ = DeletePassword(service, account)

	// Add the new item
	cmd := exec.Command("security", "add-generic-password",
		"-s", service,
		"-a", account,
		"-w", password,
		"-U", // Update if exists (backup, though we deleted first)
	)

	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to set password: %s", string(output))
	}

	return nil
}

// DeletePassword removes a password from the macOS Keychain
func DeletePassword(service, account string) error {
	cmd := exec.Command("security", "delete-generic-password",
		"-s", service,
		"-a", account,
	)

	if err := cmd.Run(); err != nil {
		// Ignore "item not found" errors
		if exitErr, ok := err.(*exec.ExitError); ok {
			if exitErr.ExitCode() == 44 {
				return nil
			}
		}
		return fmt.Errorf("failed to delete password: %w", err)
	}

	return nil
}

// ListAccounts returns all account names for a given service
func ListAccounts(service string) ([]string, error) {
	// Use security dump-keychain and grep for our service
	// This is a bit hacky but there's no clean way to list accounts via CLI
	cmd := exec.Command("security", "dump-keychain")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to dump keychain: %w", err)
	}

	return parseAccountsFromDump(string(output), service), nil
}

// parseAccountsFromDump extracts account names for a service from keychain dump
func parseAccountsFromDump(dump, service string) []string {
	var accounts []string
	lines := strings.Split(dump, "\n")

	inMatchingItem := false
	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Check if this is our service
		if strings.Contains(line, fmt.Sprintf(`"svce"<blob>="%s"`, service)) {
			inMatchingItem = true
			continue
		}

		// Extract account from matching item
		if inMatchingItem && strings.HasPrefix(line, `"acct"<blob>="`) {
			// Extract account name between quotes
			start := strings.Index(line, `="`) + 2
			end := strings.LastIndex(line, `"`)
			if start > 1 && end > start {
				account := line[start:end]
				accounts = append(accounts, account)
			}
			inMatchingItem = false
		}

		// Reset on new keychain item
		if strings.HasPrefix(line, "keychain:") {
			inMatchingItem = false
		}
	}

	return accounts
}

// Exists checks if a keychain item exists
func Exists(service, account string) bool {
	_, err := GetPassword(service, account)
	return err == nil
}

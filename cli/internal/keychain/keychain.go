// Package keychain provides cross-platform credential storage.
// On macOS it uses the security CLI, on Linux it uses secret-tool (libsecret).
package keychain

import "errors"

var (
	// ErrNotFound is returned when a keychain item doesn't exist
	ErrNotFound = errors.New("keychain item not found")
)

// Exists checks if a keychain item exists
func Exists(service, account string) bool {
	_, err := GetPassword(service, account)
	return err == nil
}

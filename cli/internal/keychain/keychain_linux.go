package keychain

import (
	"fmt"
	"os/exec"
	"strings"
)

// GetPassword retrieves a password using secret-tool (libsecret)
func GetPassword(service, account string) (string, error) {
	cmd := exec.Command("secret-tool", "lookup", "service", service, "account", account)

	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			if exitErr.ExitCode() == 1 {
				return "", ErrNotFound
			}
		}
		return "", fmt.Errorf("failed to get password: %w", err)
	}

	result := strings.TrimSpace(string(output))
	if result == "" {
		return "", ErrNotFound
	}
	return result, nil
}

// SetPassword stores a password using secret-tool (libsecret)
func SetPassword(service, account, password string) error {
	cmd := exec.Command("secret-tool", "store",
		"--label", fmt.Sprintf("durian: %s", account),
		"service", service,
		"account", account,
	)
	cmd.Stdin = strings.NewReader(password)

	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to set password: %s", string(output))
	}

	return nil
}

// DeletePassword removes a password using secret-tool (libsecret)
func DeletePassword(service, account string) error {
	cmd := exec.Command("secret-tool", "clear", "service", service, "account", account)

	if err := cmd.Run(); err != nil {
		// secret-tool clear doesn't error on missing items
		return fmt.Errorf("failed to delete password: %w", err)
	}

	return nil
}

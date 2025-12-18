package config

import "errors"

var (
	// ErrNoAccounts is returned when no accounts are configured
	ErrNoAccounts = errors.New("no accounts configured")
	// ErrNoDefaultAccount is returned when no default account is found
	ErrNoDefaultAccount = errors.New("no default account configured")
	// ErrAccountNotFound is returned when the requested account is not found
	ErrAccountNotFound = errors.New("account not found")
	// ErrSignatureNotFound is returned when the requested signature is not found
	ErrSignatureNotFound = errors.New("signature not found")
)

// GetDefaultAccount returns the account marked as default
// If no account is marked default, returns the first account
func (c *Config) GetDefaultAccount() (*AccountConfig, error) {
	if len(c.Accounts) == 0 {
		return nil, ErrNoAccounts
	}

	for i := range c.Accounts {
		if c.Accounts[i].Default {
			return &c.Accounts[i], nil
		}
	}

	// Return first account if none marked as default
	return &c.Accounts[0], nil
}

// GetAccountByEmail returns the account with the given email
func (c *Config) GetAccountByEmail(email string) (*AccountConfig, error) {
	if len(c.Accounts) == 0 {
		return nil, ErrNoAccounts
	}

	for i := range c.Accounts {
		if c.Accounts[i].Email == email {
			return &c.Accounts[i], nil
		}
	}
	return nil, ErrAccountNotFound
}

// GetAccountByName returns the account with the given name
func (c *Config) GetAccountByName(name string) (*AccountConfig, error) {
	if len(c.Accounts) == 0 {
		return nil, ErrNoAccounts
	}

	for i := range c.Accounts {
		if c.Accounts[i].Name == name {
			return &c.Accounts[i], nil
		}
	}
	return nil, ErrAccountNotFound
}

// GetSignature returns the signature with the given name
func (c *Config) GetSignature(name string) (string, error) {
	if c.Signatures == nil {
		return "", ErrSignatureNotFound
	}

	sig, ok := c.Signatures[name]
	if !ok {
		return "", ErrSignatureNotFound
	}

	return sig, nil
}

// GetDatabasePath returns the expanded notmuch database path
// Returns empty string if not configured (let notmuch use default)
func (c *Config) GetDatabasePath() string {
	if c.Notmuch.DatabasePath == "" {
		return ""
	}
	return ExpandPath(c.Notmuch.DatabasePath)
}

// HasAccounts returns true if at least one account is configured
func (c *Config) HasAccounts() bool {
	return len(c.Accounts) > 0
}

// AccountCount returns the number of configured accounts
func (c *Config) AccountCount() int {
	return len(c.Accounts)
}

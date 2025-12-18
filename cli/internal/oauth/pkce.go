package oauth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
)

// PKCE contains the code verifier and challenge for OAuth 2.0 PKCE flow
type PKCE struct {
	Verifier  string
	Challenge string
	Method    string // Always "S256"
}

// GeneratePKCE generates a new PKCE code verifier and challenge
// The verifier is a cryptographically random string of 43-128 characters
// The challenge is the SHA-256 hash of the verifier, base64url encoded
func GeneratePKCE() (*PKCE, error) {
	// Generate 32 random bytes (will become 43 base64url characters)
	verifierBytes := make([]byte, 32)
	if _, err := rand.Read(verifierBytes); err != nil {
		return nil, err
	}

	// Base64url encode without padding to get verifier (43 chars)
	verifier := base64.RawURLEncoding.EncodeToString(verifierBytes)

	// SHA-256 hash the verifier
	hash := sha256.Sum256([]byte(verifier))

	// Base64url encode the hash without padding to get challenge
	challenge := base64.RawURLEncoding.EncodeToString(hash[:])

	return &PKCE{
		Verifier:  verifier,
		Challenge: challenge,
		Method:    "S256",
	}, nil
}

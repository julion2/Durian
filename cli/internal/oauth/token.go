package oauth

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var (
	// ErrTokenNotFound is returned when no token exists for the account
	ErrTokenNotFound = errors.New("no token found for this account")
	// ErrTokenExpired is returned when the token is expired and refresh failed
	ErrTokenExpired = errors.New("token expired, please re-authenticate")
	// ErrRefreshFailed is returned when token refresh fails
	ErrRefreshFailed = errors.New("failed to refresh token")
)

// Token represents an OAuth 2.0 token stored in keychain
type Token struct {
	Provider     string    `json:"provider"`
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	Expiry       time.Time `json:"expiry"`
}

// TokenResponse is the response from the OAuth token endpoint
type TokenResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token,omitempty"`
	Scope        string `json:"scope,omitempty"`
	Error        string `json:"error,omitempty"`
	ErrorDesc    string `json:"error_description,omitempty"`
}

// IsExpired returns true if the token is expired or will expire within the buffer time
func (t *Token) IsExpired() bool {
	return t.IsExpiredWithBuffer(0)
}

// IsExpiredWithBuffer returns true if the token will expire within the given duration
func (t *Token) IsExpiredWithBuffer(buffer time.Duration) bool {
	return time.Now().Add(buffer).After(t.Expiry)
}

// ExpiresIn returns the duration until the token expires
func (t *Token) ExpiresIn() time.Duration {
	return time.Until(t.Expiry)
}

// ExchangeCode exchanges an authorization code for tokens
// clientSecret is optional for Microsoft (PKCE only) but required for Google
func ExchangeCode(provider *Provider, clientID, clientSecret, redirectURI, code, codeVerifier string) (*Token, error) {
	data := url.Values{
		"client_id":     {clientID},
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {redirectURI},
		"code_verifier": {codeVerifier},
	}

	// Google requires client_secret even with PKCE
	if clientSecret != "" {
		data.Set("client_secret", clientSecret)
	}

	resp, err := http.PostForm(provider.TokenEndpoint, data)
	if err != nil {
		return nil, fmt.Errorf("token request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read token response: %w", err)
	}

	var tokenResp TokenResponse
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return nil, fmt.Errorf("failed to parse token response: %w", err)
	}

	if tokenResp.Error != "" {
		return nil, fmt.Errorf("token error: %s - %s", tokenResp.Error, tokenResp.ErrorDesc)
	}

	return &Token{
		Provider:     provider.Name,
		AccessToken:  tokenResp.AccessToken,
		RefreshToken: tokenResp.RefreshToken,
		Expiry:       time.Now().Add(time.Duration(tokenResp.ExpiresIn) * time.Second),
	}, nil
}

// RefreshAccessToken uses the refresh token to get a new access token
// clientSecret is optional for Microsoft but required for Google
func RefreshAccessToken(provider *Provider, clientID, clientSecret string, token *Token) (*Token, error) {
	if token.RefreshToken == "" {
		return nil, errors.New("no refresh token available")
	}

	data := url.Values{
		"client_id":     {clientID},
		"grant_type":    {"refresh_token"},
		"refresh_token": {token.RefreshToken},
		"scope":         {strings.Join(provider.Scopes, " ")},
	}

	// Google requires client_secret for refresh
	if clientSecret != "" {
		data.Set("client_secret", clientSecret)
	}

	resp, err := http.PostForm(provider.TokenEndpoint, data)
	if err != nil {
		return nil, fmt.Errorf("refresh request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read refresh response: %w", err)
	}

	var tokenResp TokenResponse
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return nil, fmt.Errorf("failed to parse refresh response: %w", err)
	}

	if tokenResp.Error != "" {
		// If refresh token is invalid, user needs to re-authenticate
		if tokenResp.Error == "invalid_grant" {
			return nil, ErrTokenExpired
		}
		return nil, fmt.Errorf("refresh error: %s - %s", tokenResp.Error, tokenResp.ErrorDesc)
	}

	// Keep the old refresh token if a new one wasn't provided
	refreshToken := tokenResp.RefreshToken
	if refreshToken == "" {
		refreshToken = token.RefreshToken
	}

	return &Token{
		Provider:     provider.Name,
		AccessToken:  tokenResp.AccessToken,
		RefreshToken: refreshToken,
		Expiry:       time.Now().Add(time.Duration(tokenResp.ExpiresIn) * time.Second),
	}, nil
}

// GetValidToken loads a token and refreshes it if needed
// Returns a valid access token ready for use
func GetValidToken(email, clientID, tenant string) (*Token, error) {
	token, err := LoadToken(email)
	if err != nil {
		return nil, err
	}

	// If token is still valid (with 5 minute buffer), return it
	if !token.IsExpiredWithBuffer(5 * time.Minute) {
		return token, nil
	}

	// Token expired or expiring soon, try to refresh
	provider, err := GetProvider(token.Provider, tenant)
	if err != nil {
		return nil, err
	}

	newToken, err := RefreshAccessToken(provider, clientID, "", token)
	if err != nil {
		// If refresh failed, delete the invalid token
		if errors.Is(err, ErrTokenExpired) {
			_ = DeleteToken(email)
		}
		return nil, err
	}

	// Save the refreshed token
	if err := SaveToken(email, newToken); err != nil {
		return nil, fmt.Errorf("failed to save refreshed token: %w", err)
	}

	return newToken, nil
}

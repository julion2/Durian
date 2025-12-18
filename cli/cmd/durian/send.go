package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/durian-dev/durian/cli/internal/config"
	"github.com/durian-dev/durian/cli/internal/oauth"
	"github.com/durian-dev/durian/cli/internal/smtp"
	"github.com/spf13/cobra"
)

var (
	sendTo      string
	sendSubject string
	sendBody    string
	sendFrom    string
	sendAttach  string
)

var sendCmd = &cobra.Command{
	Use:   "send",
	Short: "Send an email via SMTP",
	Long: `Send an email via SMTP with OAuth2 or password authentication.

Examples:
  # Send with all flags
  durian send --to "recipient@example.com" --subject "Hello" --body "Message"

  # Send with attachment
  durian send --to "..." --subject "..." --body "..." --attach file.pdf

  # Interactive mode (prompts for missing fields, opens $EDITOR for body)
  durian send --to "recipient@example.com" --subject "Hello"

  # Specify sender account
  durian send --from "work@company.com" --to "..." --subject "..." --body "..."`,
	RunE: runSend,
}

func init() {
	sendCmd.Flags().StringVar(&sendTo, "to", "", "recipient email address(es), comma-separated")
	sendCmd.Flags().StringVar(&sendSubject, "subject", "", "email subject")
	sendCmd.Flags().StringVar(&sendBody, "body", "", "email body")
	sendCmd.Flags().StringVar(&sendFrom, "from", "", "sender email (uses default account if not specified)")
	sendCmd.Flags().StringVar(&sendAttach, "attach", "", "attach a file")

	rootCmd.AddCommand(sendCmd)
}

func runSend(cmd *cobra.Command, args []string) error {
	cfg := GetConfig()
	if cfg == nil {
		return errors.New("no configuration loaded")
	}

	// Get sender account
	var account *config.AccountConfig
	var err error

	if sendFrom != "" {
		account, err = cfg.GetAccountByEmail(sendFrom)
		if err != nil {
			return fmt.Errorf("account not found: %s", sendFrom)
		}
	} else {
		account, err = cfg.GetDefaultAccount()
		if err != nil {
			return fmt.Errorf("no default account configured\nUse --from to specify an account or set default=true in config.toml")
		}
	}

	// Check SMTP config
	if account.SMTP.Host == "" {
		return fmt.Errorf("no SMTP host configured for %s", account.Email)
	}

	// Get To address (prompt if not provided)
	to := sendTo
	if to == "" {
		to, err = prompt("To: ")
		if err != nil {
			return err
		}
	}
	if to == "" {
		return errors.New("at least one recipient required")
	}

	// Parse recipients
	recipients, err := smtp.ParseAddressList(to)
	if err != nil {
		return err
	}

	// Get Subject (prompt if not provided)
	subject := sendSubject
	if subject == "" {
		subject, err = prompt("Subject: ")
		if err != nil {
			return err
		}
	}

	// Get Body (open editor if not provided)
	body := sendBody
	if body == "" {
		body, err = openEditor(to, subject)
		if err != nil {
			return err
		}
	}
	if strings.TrimSpace(body) == "" {
		return errors.New("empty message body, aborting")
	}

	// Build message
	msg := &smtp.Message{
		From:    account.Email,
		To:      recipients,
		Subject: subject,
		Body:    body,
	}

	// Load attachment if specified
	if sendAttach != "" {
		att, err := smtp.LoadAttachment(sendAttach)
		if err != nil {
			return err
		}
		msg.Attachments = []smtp.Attachment{*att}
		fmt.Fprintf(os.Stderr, "Attaching: %s (%s)\n", att.Filename, att.MIMEType)
	}

	// Get authentication
	auth, err := getAuth(account)
	if err != nil {
		return err
	}

	// Send
	fmt.Fprintf(os.Stderr, "Connecting to %s:%d...\n", account.SMTP.Host, account.SMTP.Port)

	client := smtp.NewClient(account.SMTP.Host, account.SMTP.Port, auth)
	if err := client.Send(msg); err != nil {
		return fmt.Errorf("failed to send email: %w", err)
	}

	fmt.Fprintf(os.Stderr, "✓ Email sent successfully to %s\n", to)
	return nil
}

// getAuth returns the appropriate auth method for the account
func getAuth(account *config.AccountConfig) (smtp.Auth, error) {
	switch account.SMTP.Auth {
	case "oauth2":
		// Get OAuth token
		if account.OAuth.Provider == "" {
			return nil, fmt.Errorf("OAuth provider not configured for %s", account.Email)
		}

		token, err := oauth.GetValidToken(account.Email, account.OAuth.ClientID, account.OAuth.Tenant)
		if err != nil {
			if errors.Is(err, oauth.ErrTokenNotFound) {
				return nil, fmt.Errorf("not authenticated\nRun: durian auth login %s", account.Email)
			}
			if errors.Is(err, oauth.ErrTokenExpired) {
				return nil, fmt.Errorf("authentication expired\nRun: durian auth login %s", account.Email)
			}
			return nil, fmt.Errorf("failed to get OAuth token: %w", err)
		}

		fmt.Fprintf(os.Stderr, "Using OAuth2 authentication for %s\n", account.Email)
		return &smtp.OAuth2Auth{
			Email:       account.Email,
			AccessToken: token.AccessToken,
		}, nil

	case "password":
		// Get password from keychain
		if account.Auth.PasswordKeychain == "" {
			return nil, fmt.Errorf("password_keychain not configured for %s", account.Email)
		}

		password, err := getPasswordFromKeychain(account.Auth.PasswordKeychain, account.Auth.Username)
		if err != nil {
			return nil, fmt.Errorf("failed to get password from keychain: %w", err)
		}

		username := account.Auth.Username
		if username == "" {
			username = account.Email
		}

		fmt.Fprintf(os.Stderr, "Using password authentication for %s\n", account.Email)
		return &smtp.PasswordAuth{
			Username: username,
			Password: password,
		}, nil

	default:
		return nil, fmt.Errorf("unsupported auth method: %s\nUse 'oauth2' or 'password'", account.SMTP.Auth)
	}
}

// getPasswordFromKeychain retrieves a password from macOS Keychain
func getPasswordFromKeychain(service, account string) (string, error) {
	cmd := exec.Command("security", "find-generic-password", "-s", service, "-a", account, "-w")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("keychain entry not found: %s", service)
	}
	return strings.TrimSpace(string(output)), nil
}

// prompt displays a prompt and reads a line of input
func prompt(message string) (string, error) {
	fmt.Fprint(os.Stderr, message)
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

// openEditor opens $EDITOR for the user to write the email body
func openEditor(to, subject string) (string, error) {
	// Create temp file with template
	tmpfile, err := os.CreateTemp("", "durian-*.txt")
	if err != nil {
		return "", fmt.Errorf("failed to create temp file: %w", err)
	}
	tmpPath := tmpfile.Name()
	defer os.Remove(tmpPath)

	// Write template
	template := fmt.Sprintf(`
# Write your message above this line.
# Lines starting with # will be ignored.
# To: %s
# Subject: %s
# 
# Save and close the editor to send, or delete all text to cancel.
`, to, subject)

	if _, err := tmpfile.WriteString(template); err != nil {
		tmpfile.Close()
		return "", fmt.Errorf("failed to write template: %w", err)
	}
	tmpfile.Close()

	// Determine editor
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = os.Getenv("VISUAL")
	}
	if editor == "" {
		// Try common editors
		for _, e := range []string{"vim", "nano", "vi"} {
			if _, err := exec.LookPath(e); err == nil {
				editor = e
				break
			}
		}
	}
	if editor == "" {
		return "", errors.New("no editor found. Set $EDITOR environment variable")
	}

	// Open editor
	cmd := exec.Command(editor, tmpPath)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("editor failed: %w", err)
	}

	// Read result
	file, err := os.Open(tmpPath)
	if err != nil {
		return "", fmt.Errorf("failed to read edited file: %w", err)
	}
	defer file.Close()

	body, err := smtp.ReadBody(file)
	if err != nil {
		return "", fmt.Errorf("failed to parse body: %w", err)
	}

	return body, nil
}

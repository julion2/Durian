package contacts

import (
	"bufio"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// ImportFromNotmuch imports contacts from a notmuch database
// It extracts unique email addresses from From, To, Cc headers
// Returns the list of contacts found and any error
// Note: notmuch uses its default config/database location automatically
func ImportFromNotmuch() ([]Contact, error) {
	// Build notmuch address command
	// --output=sender gets From addresses
	// --output=count includes usage count for each address
	// --deduplicate=address removes duplicates by email
	args := []string{"address", "--output=sender", "--output=count", "--deduplicate=address", "*"}

	cmd := exec.Command("notmuch", args...)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("notmuch address failed: %s", string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("notmuch address failed: %w", err)
	}

	contacts := parseAddressOutput(string(output))

	// Also get recipient addresses (To, Cc)
	argsRecipients := []string{"address", "--output=recipients", "--output=count", "--deduplicate=address", "*"}

	cmdRecipients := exec.Command("notmuch", argsRecipients...)
	outputRecipients, err := cmdRecipients.Output()
	if err == nil {
		recipientContacts := parseAddressOutput(string(outputRecipients))
		contacts = mergeContacts(contacts, recipientContacts)
	}

	return contacts, nil
}

// parseAddressOutput parses the output of notmuch address with count
// Each line is in format: "<count>\t<address>"
// Where address is either:
// - "Name <email@example.com>"
// - "email@example.com"
func parseAddressOutput(output string) []Contact {
	var contacts []Contact
	seen := make(map[string]bool)
	now := time.Now()

	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		// Parse count and address from "count\taddress" format
		usageCount := 0
		addressPart := line

		if idx := strings.Index(line, "\t"); idx != -1 {
			countStr := strings.TrimSpace(line[:idx])
			if count, err := strconv.Atoi(countStr); err == nil {
				usageCount = count
			}
			addressPart = strings.TrimSpace(line[idx+1:])
		}

		email, name := parseAddress(addressPart)
		if email == "" {
			continue
		}

		// Normalize email to lowercase
		email = strings.ToLower(email)

		// Skip if already seen
		if seen[email] {
			continue
		}
		seen[email] = true

		// Skip invalid-looking emails
		if !isValidEmail(email) {
			continue
		}

		contacts = append(contacts, Contact{
			ID:         uuid.New().String(),
			Email:      email,
			Name:       name,
			UsageCount: usageCount,
			Source:     SourceImported,
			CreatedAt:  now,
		})
	}

	return contacts
}

// parseAddress extracts email and name from an address string
// Handles formats:
// - "Name <email@example.com>"
// - "<email@example.com>"
// - "email@example.com"
// - "email@example.com (Name)"
func parseAddress(addr string) (email, name string) {
	addr = strings.TrimSpace(addr)

	// Format: "Name <email>"
	if idx := strings.LastIndex(addr, "<"); idx != -1 {
		if end := strings.LastIndex(addr, ">"); end > idx {
			email = strings.TrimSpace(addr[idx+1 : end])
			name = strings.TrimSpace(addr[:idx])
			// Remove surrounding quotes from name
			name = strings.Trim(name, `"'`)
			return
		}
	}

	// Format: "email (Name)"
	if idx := strings.LastIndex(addr, "("); idx != -1 {
		if end := strings.LastIndex(addr, ")"); end > idx {
			name = strings.TrimSpace(addr[idx+1 : end])
			email = strings.TrimSpace(addr[:idx])
			return
		}
	}

	// Plain email
	email = addr
	return
}

// isValidEmail does basic email validation
func isValidEmail(email string) bool {
	// Simple regex for email validation
	// This is intentionally permissive
	pattern := `^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$`
	matched, _ := regexp.MatchString(pattern, email)
	return matched
}

// mergeContacts merges two contact lists, preferring entries with names
// and combining usage counts
func mergeContacts(existing, new []Contact) []Contact {
	byEmail := make(map[string]*Contact)

	// Index existing contacts
	for i := range existing {
		byEmail[existing[i].Email] = &existing[i]
	}

	// Merge new contacts
	for _, c := range new {
		if existing, ok := byEmail[c.Email]; ok {
			// Update name if we didn't have one
			if existing.Name == "" && c.Name != "" {
				existing.Name = c.Name
			}
			// Add usage counts together (sender + recipient counts)
			existing.UsageCount += c.UsageCount
		} else {
			// Add new contact
			byEmail[c.Email] = &Contact{
				ID:         c.ID,
				Email:      c.Email,
				Name:       c.Name,
				UsageCount: c.UsageCount,
				Source:     c.Source,
				CreatedAt:  c.CreatedAt,
			}
		}
	}

	// Convert back to slice
	result := make([]Contact, 0, len(byEmail))
	for _, c := range byEmail {
		result = append(result, *c)
	}

	return result
}

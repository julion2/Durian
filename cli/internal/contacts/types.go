package contacts

import "time"

// Contact represents a single contact in the address book
type Contact struct {
	ID         string    `json:"id"`
	Email      string    `json:"email"`
	Name       string    `json:"name,omitempty"`
	LastUsed   time.Time `json:"last_used,omitempty"`
	UsageCount int       `json:"usage_count"`
	Source     string    `json:"source"` // "imported", "manual", "sent"
	CreatedAt  time.Time `json:"created_at"`
}

// ContactSource defines how a contact was added
const (
	SourceImported = "imported" // Imported from notmuch
	SourceManual   = "manual"   // Manually added
	SourceSent     = "sent"     // Added when email was sent
)

// FormatDisplay returns a display string for the contact
// Returns "Name <email>" if name exists, otherwise just "email"
func (c *Contact) FormatDisplay() string {
	if c.Name != "" {
		return c.Name + " <" + c.Email + ">"
	}
	return c.Email
}

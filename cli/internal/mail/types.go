package mail

// Mail represents a mail summary for list views
type Mail struct {
	ThreadID string `json:"thread_id"`
	File     string `json:"file"`
	Subject  string `json:"subject"`
	From     string `json:"from"`
	Date     string `json:"date"`
	Tags     string `json:"tags"`
}

// MailContent represents the full content of an email
type MailContent struct {
	From        string   `json:"from"`
	To          string   `json:"to"`
	Subject     string   `json:"subject"`
	Date        string   `json:"date"`
	Body        string   `json:"body"`
	HTML        string   `json:"html,omitempty"`
	Attachments []string `json:"attachments,omitempty"`
}

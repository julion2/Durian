package mail

// Mail represents a mail summary for list views
type Mail struct {
	ThreadID  string `json:"thread_id"`
	File      string `json:"file"`
	Subject   string `json:"subject"`
	From      string `json:"from"`
	Date      string `json:"date"`
	Timestamp int64  `json:"timestamp"`
	Tags      string `json:"tags"`
}

// MailContent represents the full content of an email
type MailContent struct {
	From        string   `json:"from"`
	To          string   `json:"to"`
	CC          string   `json:"cc,omitempty"`
	Subject     string   `json:"subject"`
	Date        string   `json:"date"`
	MessageID   string   `json:"message_id,omitempty"`
	InReplyTo   string   `json:"in_reply_to,omitempty"`
	References  string   `json:"references,omitempty"`
	Body        string   `json:"body"`
	HTML        string   `json:"html,omitempty"`
	Attachments []string `json:"attachments,omitempty"`
}

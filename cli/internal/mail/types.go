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

// ThreadContent represents a complete email thread with all messages
type ThreadContent struct {
	ThreadID string        `json:"thread_id"`
	Subject  string        `json:"subject"`
	Messages []MessageInfo `json:"messages"`
}

// MessageInfo represents a single message within a thread
type MessageInfo struct {
	ID          string   `json:"id"`
	From        string   `json:"from"`
	To          string   `json:"to,omitempty"`
	CC          string   `json:"cc,omitempty"`
	Date        string   `json:"date"`
	Timestamp   int64    `json:"timestamp"`
	Body        string   `json:"body"`
	HTML        string   `json:"html,omitempty"`
	Attachments []string `json:"attachments,omitempty"`
	Tags        []string `json:"tags,omitempty"`
}

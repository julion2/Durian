package mail

import (
	"bytes"
	"io"
	"mime"
	"mime/multipart"
	"net/mail"
	"strings"

	"github.com/durian-dev/durian/cli/internal/encoding"
	"github.com/durian-dev/durian/cli/internal/sanitize"
)

// Parser handles MIME parsing of email messages
type Parser struct{}

// NewParser creates a new mail parser
func NewParser() *Parser {
	return &Parser{}
}

// Parse extracts content from a mail.Message and returns MailContent
func (p *Parser) Parse(msg *mail.Message) *MailContent {
	content := &MailContent{
		From:       encoding.DecodeHeader(msg.Header.Get("From")),
		To:         encoding.DecodeHeader(msg.Header.Get("To")),
		CC:         encoding.DecodeHeader(msg.Header.Get("Cc")),
		Subject:    encoding.DecodeHeader(msg.Header.Get("Subject")),
		Date:       msg.Header.Get("Date"),
		MessageID:  msg.Header.Get("Message-ID"),
		InReplyTo:  msg.Header.Get("In-Reply-To"),
		References: msg.Header.Get("References"),
	}

	textBody, htmlBody, attachments := p.extractBody(msg)
	content.Body = textBody
	content.HTML = sanitize.SanitizeHTML(htmlBody)
	content.Attachments = attachments

	return content
}

// extractBody extracts text, HTML and attachments from a mail message
func (p *Parser) extractBody(msg *mail.Message) (string, string, []AttachmentInfo) {
	contentType := msg.Header.Get("Content-Type")
	transferEncoding := msg.Header.Get("Content-Transfer-Encoding")
	charset := encoding.GetCharset(contentType)

	if contentType == "" {
		contentType = "text/plain"
	}

	mediaType, params, _ := mime.ParseMediaType(contentType)
	var attachments []AttachmentInfo

	if strings.HasPrefix(mediaType, "text/plain") {
		body, _ := io.ReadAll(msg.Body)
		text := encoding.DecodeBody(body, transferEncoding, charset)
		return text, "", nil
	}

	if strings.HasPrefix(mediaType, "text/html") {
		body, _ := io.ReadAll(msg.Body)
		html := encoding.DecodeBody(body, transferEncoding, charset)
		return encoding.HTMLToText(html), html, nil
	}

	if strings.HasPrefix(mediaType, "multipart/") {
		return p.extractMultipart(msg.Body, params["boundary"])
	}

	body, _ := io.ReadAll(msg.Body)
	return encoding.DecodeBody(body, transferEncoding, charset), "", attachments
}

// extractMultipart recursively extracts content from multipart messages
func (p *Parser) extractMultipart(r io.Reader, boundary string) (string, string, []AttachmentInfo) {
	mr := multipart.NewReader(r, boundary)
	var textContent, htmlContent string
	var attachments []AttachmentInfo

	for {
		part, err := mr.NextPart()
		if err != nil {
			break
		}

		contentType := part.Header.Get("Content-Type")
		contentDisp := part.Header.Get("Content-Disposition")
		transferEncoding := part.Header.Get("Content-Transfer-Encoding")
		charset := encoding.GetCharset(contentType)
		mediaType, params, _ := mime.ParseMediaType(contentType)

		if strings.Contains(contentDisp, "attachment") || (part.FileName() != "" && !strings.HasPrefix(mediaType, "text/")) {
			name := encoding.DecodeHeader(part.FileName())
			if name == "" {
				name = "unnamed"
			}
			disposition := "attachment"
			if strings.Contains(contentDisp, "inline") {
				disposition = "inline"
			}
			attBody, _ := io.ReadAll(part)
			attachments = append(attachments, AttachmentInfo{
				Filename:    name,
				ContentType: mediaType,
				Size:        len(attBody),
				Disposition: disposition,
				ContentID:   part.Header.Get("Content-Id"),
			})
			continue
		}

		body, _ := io.ReadAll(part)

		if strings.HasPrefix(mediaType, "text/plain") && textContent == "" {
			textContent = encoding.DecodeBody(body, transferEncoding, charset)
		} else if strings.HasPrefix(mediaType, "text/html") && htmlContent == "" {
			htmlContent = encoding.DecodeBody(body, transferEncoding, charset)
		} else if strings.HasPrefix(mediaType, "multipart/") {
			nested, nestedHTML, atts := p.extractMultipart(bytes.NewReader(body), params["boundary"])
			if textContent == "" {
				textContent = nested
			}
			if htmlContent == "" {
				htmlContent = nestedHTML
			}
			attachments = append(attachments, atts...)
		}
	}

	if textContent == "" && htmlContent != "" {
		textContent = encoding.HTMLToText(htmlContent)
	}

	return textContent, htmlContent, attachments
}

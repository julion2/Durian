package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/transform"
)

type Command struct {
	Cmd    string `json:"cmd"`
	Query  string `json:"query,omitempty"`
	File   string `json:"file,omitempty"`
	Thread string `json:"thread,omitempty"`
	Tags   string `json:"tags,omitempty"`
	Limit  int    `json:"limit,omitempty"`
}

type Mail struct {
	ThreadID string `json:"thread_id"`
	File     string `json:"file"`
	Subject  string `json:"subject"`
	From     string `json:"from"`
	Date     string `json:"date"`
	Tags     string `json:"tags"`
}

type MailContent struct {
	From        string   `json:"from"`
	To          string   `json:"to"`
	Subject     string   `json:"subject"`
	Date        string   `json:"date"`
	Body        string   `json:"body"`
	HTML        string   `json:"html,omitempty"`
	Attachments []string `json:"attachments,omitempty"`
}

type Response struct {
	OK      bool         `json:"ok"`
	Error   string       `json:"error,omitempty"`
	Results []Mail       `json:"results,omitempty"`
	Mail    *MailContent `json:"mail,omitempty"`
}

func search(query string, limit int) Response {
	if limit == 0 {
		limit = 50
	}
	cmd := exec.Command("notmuch", "search", "--format=json", "--limit="+strconv.Itoa(limit), query)
	out, err := cmd.Output()
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}

	var results []struct {
		Thread       string   `json:"thread"`
		Subject      string   `json:"subject"`
		Authors      string   `json:"authors"`
		DateRelative string   `json:"date_relative"`
		Tags         []string `json:"tags"`
	}
	json.Unmarshal(out, &results)

	mails := make([]Mail, len(results))
	for i, r := range results {
		mails[i] = Mail{
			ThreadID: r.Thread,
			File:     "", // Skip file lookup - use showByThread instead
			Subject:  r.Subject,
			From:     r.Authors,
			Date:     r.DateRelative,
			Tags:     strings.Join(r.Tags, ","),
		}
	}

	return Response{OK: true, Results: mails}
}

func showByThread(thread string) Response {
	cmd := exec.Command("notmuch", "search", "--output=files", "--limit=1", "thread:"+thread)
	out, err := cmd.Output()
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	files := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(files) == 0 || files[0] == "" {
		return Response{OK: false, Error: "no file found"}
	}
	return show(files[0])
}

func convertToUTF8(data []byte, charset string) string {
	charset = strings.ToLower(strings.TrimSpace(charset))
	
	if (charset == "" || charset == "utf-8" || charset == "us-ascii") && utf8.Valid(data) {
		return string(data)
	}
	
	var decoder *transform.Reader
	switch charset {
	case "iso-8859-1", "latin1", "latin-1":
		decoder = transform.NewReader(bytes.NewReader(data), charmap.ISO8859_1.NewDecoder())
	case "iso-8859-15", "latin9":
		decoder = transform.NewReader(bytes.NewReader(data), charmap.ISO8859_15.NewDecoder())
	case "windows-1252", "cp1252":
		decoder = transform.NewReader(bytes.NewReader(data), charmap.Windows1252.NewDecoder())
	default:
		if !utf8.Valid(data) {
			decoder = transform.NewReader(bytes.NewReader(data), charmap.Windows1252.NewDecoder())
		} else {
			return string(data)
		}
	}
	
	result, err := io.ReadAll(decoder)
	if err != nil {
		return string(data)
	}
	return string(result)
}

func decodeBody(body []byte, encoding string, charset string) string {
	encodingLower := strings.ToLower(encoding)
	
	var decoded []byte
	
	if strings.Contains(encodingLower, "base64") {
		var err error
		decoded, err = base64.StdEncoding.DecodeString(strings.TrimSpace(string(body)))
		if err != nil {
			decoded = body
		}
	} else if strings.Contains(encodingLower, "quoted-printable") {
		reader := quotedprintable.NewReader(bytes.NewReader(body))
		var err error
		decoded, err = io.ReadAll(reader)
		if err != nil {
			decoded = body
		}
	} else {
		decoded = body
	}
	
	return convertToUTF8(decoded, charset)
}

func getCharset(contentType string) string {
	_, params, _ := mime.ParseMediaType(contentType)
	return params["charset"]
}

func show(file string) Response {
	f, err := os.Open(file)
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	defer f.Close()

	msg, err := mail.ReadMessage(f)
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}

	content := &MailContent{
		From:    decodeHeader(msg.Header.Get("From")),
		To:      decodeHeader(msg.Header.Get("To")),
		Subject: decodeHeader(msg.Header.Get("Subject")),
		Date:    msg.Header.Get("Date"),
	}

	textBody, htmlBody, attachments := extractBody(msg)
	content.Body = textBody
	content.HTML = htmlBody
	content.Attachments = attachments

	return Response{OK: true, Mail: content}
}

func decodeHeader(header string) string {
	dec := new(mime.WordDecoder)
	decoded, err := dec.DecodeHeader(header)
	if err != nil {
		return header
	}
	return decoded
}

func extractBody(msg *mail.Message) (string, string, []string) {
	contentType := msg.Header.Get("Content-Type")
	encoding := msg.Header.Get("Content-Transfer-Encoding")
	charset := getCharset(contentType)
	
	if contentType == "" {
		contentType = "text/plain"
	}

	mediaType, params, _ := mime.ParseMediaType(contentType)
	var attachments []string

	if strings.HasPrefix(mediaType, "text/plain") {
		body, _ := io.ReadAll(msg.Body)
		text := decodeBody(body, encoding, charset)
		return text, "", nil
	}

	if strings.HasPrefix(mediaType, "text/html") {
		body, _ := io.ReadAll(msg.Body)
		html := decodeBody(body, encoding, charset)
		return htmlToText(html), html, nil
	}

	if strings.HasPrefix(mediaType, "multipart/") {
		return extractMultipart(msg.Body, params["boundary"])
	}

	body, _ := io.ReadAll(msg.Body)
	return decodeBody(body, encoding, charset), "", attachments
}

func extractMultipart(r io.Reader, boundary string) (string, string, []string) {
	mr := multipart.NewReader(r, boundary)
	var textContent, htmlContent string
	var attachments []string

	for {
		part, err := mr.NextPart()
		if err != nil {
			break
		}

		contentType := part.Header.Get("Content-Type")
		contentDisp := part.Header.Get("Content-Disposition")
		encoding := part.Header.Get("Content-Transfer-Encoding")
		charset := getCharset(contentType)
		mediaType, params, _ := mime.ParseMediaType(contentType)

		if strings.Contains(contentDisp, "attachment") {
			name := part.FileName()
			if name == "" {
				name = "unnamed"
			}
			attachments = append(attachments, name)
			continue
		}

		body, _ := io.ReadAll(part)

		if strings.HasPrefix(mediaType, "text/plain") && textContent == "" {
			textContent = decodeBody(body, encoding, charset)
		} else if strings.HasPrefix(mediaType, "text/html") && htmlContent == "" {
			htmlContent = decodeBody(body, encoding, charset)
		} else if strings.HasPrefix(mediaType, "multipart/") {
			nested, nestedHTML, atts := extractMultipart(bytes.NewReader(body), params["boundary"])
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
		textContent = htmlToText(htmlContent)
	}

	return textContent, htmlContent, attachments
}

func htmlToText(html string) string {
	cmd := exec.Command("w3m", "-T", "text/html", "-I", "UTF-8", "-O", "UTF-8", "-dump")
	cmd.Stdin = strings.NewReader(html)
	out, err := cmd.Output()
	if err != nil {
		result := html
		for strings.Contains(result, "<") {
			start := strings.Index(result, "<")
			end := strings.Index(result, ">")
			if end > start {
				result = result[:start] + result[end+1:]
			} else {
				break
			}
		}
		return result
	}
	return string(out)
}

func tag(query, tags string) Response {
	args := append([]string{"tag"}, strings.Fields(tags)...)
	args = append(args, "--", query)
	cmd := exec.Command("notmuch", args...)
	err := cmd.Run()
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return Response{OK: true}
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	encoder := json.NewEncoder(os.Stdout)

	for scanner.Scan() {
		var cmd Command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			encoder.Encode(Response{OK: false, Error: "invalid json"})
			continue
		}

		var resp Response
		switch cmd.Cmd {
		case "search":
			resp = search(cmd.Query, cmd.Limit)
		case "show":
			if cmd.Thread != "" {
				resp = showByThread(cmd.Thread)
			} else {
				resp = show(cmd.File)
			}
		case "tag":
			resp = tag(cmd.Query, cmd.Tags)
		default:
			resp = Response{OK: false, Error: "unknown command"}
		}
		encoder.Encode(resp)
	}
}

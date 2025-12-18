package encoding

import (
	"bytes"
	"io"
	"mime"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/transform"
)

// ConvertToUTF8 converts data from the given charset to UTF-8
func ConvertToUTF8(data []byte, charset string) string {
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

// GetCharset extracts the charset from a Content-Type header value
func GetCharset(contentType string) string {
	_, params, _ := mime.ParseMediaType(contentType)
	return params["charset"]
}

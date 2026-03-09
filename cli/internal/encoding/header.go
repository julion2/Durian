package encoding

import (
	"io"
	"mime"
	"strings"

	"golang.org/x/text/encoding/charmap"
)

// DecodeHeader decodes RFC 2047 encoded-word headers (e.g., =?UTF-8?Q?...?=)
func DecodeHeader(header string) string {
	dec := new(mime.WordDecoder)
	dec.CharsetReader = charsetReader
	decoded, err := dec.DecodeHeader(header)
	if err != nil {
		return header
	}
	return decoded
}

// charsetReader returns a reader that converts from the given charset to UTF-8.
// Used by mime.WordDecoder to handle non-UTF-8 RFC 2047 encoded words.
func charsetReader(charset string, input io.Reader) (io.Reader, error) {
	switch strings.ToLower(strings.TrimSpace(charset)) {
	case "iso-8859-1", "latin1", "latin-1":
		return charmap.ISO8859_1.NewDecoder().Reader(input), nil
	case "iso-8859-15", "latin9":
		return charmap.ISO8859_15.NewDecoder().Reader(input), nil
	case "windows-1252", "cp1252":
		return charmap.Windows1252.NewDecoder().Reader(input), nil
	default:
		// Return input as-is for UTF-8/ASCII/unknown; mime.WordDecoder
		// handles UTF-8 natively and will error on truly unsupported charsets.
		return input, nil
	}
}

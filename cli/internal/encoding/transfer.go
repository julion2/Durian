package encoding

import (
	"bytes"
	"encoding/base64"
	"io"
	"mime/quotedprintable"
	"strings"
)

// DecodeBody decodes the body based on Content-Transfer-Encoding and converts to UTF-8
func DecodeBody(body []byte, transferEncoding string, charset string) string {
	encodingLower := strings.ToLower(transferEncoding)

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

	return ConvertToUTF8(decoded, charset)
}

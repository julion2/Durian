package encoding

import "mime"

// DecodeHeader decodes RFC 2047 encoded-word headers (e.g., =?UTF-8?Q?...?=)
func DecodeHeader(header string) string {
	dec := new(mime.WordDecoder)
	decoded, err := dec.DecodeHeader(header)
	if err != nil {
		return header
	}
	return decoded
}

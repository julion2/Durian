package sanitize

import "testing"

func TestDetectSignature(t *testing.T) {
	tests := []struct {
		name string
		html string
		want bool // true = signature found
	}{
		{"RFC 3676 div", `<div>Hello</div><div>-- <br></div><span>Sig</span>`, true},
		{"RFC 3676 self-closing br", `<div>Hello</div><div>-- <br/></div><span>Sig</span>`, true},
		{"Gmail", `<div>Hello</div><div class="gmail_signature" dir="ltr">Sig</div>`, true},
		{"Thunderbird", `<div>Hello</div><div class="moz-signature">-- <br>Sig</div>`, true},
		{"Apple Mail", `<div>Hello</div><div id="AppleMailSignature">Sig</div>`, true},
		{"Apple Mail lowercase", `<div>Hello</div><div id="applemailsignature">Sig</div>`, true},
		{"no marker", `<div>Hello World</div>`, false},
		{"dashes in text", `<div>Use -- for comments</div>`, false},
		{"empty", "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := DetectSignature(tt.html)
			if (got != -1) != tt.want {
				t.Errorf("DetectSignature() = %d, wantFound = %v", got, tt.want)
			}
		})
	}
}

func TestStripSignature(t *testing.T) {
	tests := []struct {
		name string
		html string
		want string
	}{
		{"RFC 3676", `<div>Hello</div><div>-- <br></div><span>Julian</span>`, `<div>Hello</div>`},
		{"Gmail", `<div>Hi</div><div class="gmail_signature"><span>Bob</span></div>`, `<div>Hi</div>`},
		{"Thunderbird", `<p>Hey</p><div class="moz-signature">-- <br>Alice</div>`, `<p>Hey</p>`},
		{"no marker", `<div>Hello World</div>`, `<div>Hello World</div>`},
		{"empty", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := StripSignature(tt.html)
			if got != tt.want {
				t.Errorf("StripSignature()\ngot:  %q\nwant: %q", got, tt.want)
			}
		})
	}
}

func TestCommonSuffix(t *testing.T) {
	tests := []struct {
		name string
		a, b string
		want string
	}{
		{"identical ending", "<div>Hello</div><sig>Julian</sig>", "<div>Bye</div><sig>Julian</sig>", "</div><sig>Julian</sig>"},
		{"no common", "<div>Hello</div>", "<div>Bye</div>", "</div>"},
		{"identical", "abc", "abc", "abc"},
		{"empty a", "", "abc", ""},
		{"empty both", "", "", ""},
		{"one char common", "xz", "yz", "z"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := CommonSuffix(tt.a, tt.b)
			if got != tt.want {
				t.Errorf("CommonSuffix()\ngot:  %q\nwant: %q", got, tt.want)
			}
		})
	}
}

func TestExtractSignature(t *testing.T) {
	tests := []struct {
		name string
		html string
		want string
	}{
		{"RFC 3676", `<div>Hello</div><div>-- <br></div><span>Julian</span>`,
			`<div>-- <br></div><span>Julian</span>`},
		{"Gmail", `<div>Hi</div><div class="gmail_signature">Bob</div>`,
			`<div class="gmail_signature">Bob</div>`},
		{"no marker", `<div>Hello</div>`, ""},
		{"empty", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ExtractSignature(tt.html)
			if got != tt.want {
				t.Errorf("ExtractSignature()\ngot:  %q\nwant: %q", got, tt.want)
			}
		})
	}
}

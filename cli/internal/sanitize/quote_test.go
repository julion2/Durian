package sanitize

import (
	"strings"
	"testing"
)

// assertStripped verifies that stripping keeps the reply and removes the quoted part.
func assertStripped(t *testing.T, name, input, expectedKeep, expectedRemove string) {
	t.Helper()
	result := StripQuotedContent(input)
	if expectedKeep != "" && !strings.Contains(result, expectedKeep) {
		t.Errorf("[%s] result should contain %q, got: %q", name, expectedKeep, result)
	}
	if expectedRemove != "" && strings.Contains(result, expectedRemove) {
		t.Errorf("[%s] result should NOT contain %q, got: %q", name, expectedRemove, result)
	}
}

// --- Empty / no-op cases ---

func TestStripQuotedContent_Empty(t *testing.T) {
	if StripQuotedContent("") != "" {
		t.Error("empty input should return empty")
	}
}

func TestStripQuotedContent_NoQuotes(t *testing.T) {
	html := `<p>Just a plain email with no quotes.</p>`
	result := StripQuotedContent(html)
	if result != html {
		t.Errorf("unquoted HTML should be unchanged, got: %q", result)
	}
}

func TestStripQuotedContent_PureForwardKept(t *testing.T) {
	// If stripping leaves empty content, the original should be kept
	html := `<blockquote class="gmail_quote">Forwarded content here</blockquote>`
	result := StripQuotedContent(html)
	if !strings.Contains(result, "Forwarded content here") {
		t.Error("pure forward (no reply text) should keep the original")
	}
}

// --- Outlook Web ---

func TestStripQuotedContent_OutlookWeb_ReferenceMessageContainer(t *testing.T) {
	html := `<p>My reply text</p><div id="mail-editor-reference-message-container"><p>Original</p></div>`
	assertStripped(t, "Outlook Web reference container", html, "My reply text", "Original")
}

func TestStripQuotedContent_OutlookWeb_AppendOnSend(t *testing.T) {
	html := `<p>My reply</p><div id="appendonsend"><p>quoted</p></div>`
	assertStripped(t, "Outlook appendonsend", html, "My reply", "quoted")
}

func TestStripQuotedContent_OutlookWeb_DivRplyFwdMsg(t *testing.T) {
	html := `<p>Reply above</p><div id="divRplyFwdMsg"><b>From:</b> Someone</div>`
	assertStripped(t, "Outlook divRplyFwdMsg", html, "Reply above", "Someone")
}

func TestStripQuotedContent_OutlookWeb_DivRplyFwdMsgByName(t *testing.T) {
	html := `<p>Reply</p><div name="divRplyFwdMsg">Original msg</div>`
	assertStripped(t, "Outlook divRplyFwdMsg (name attr)", html, "Reply", "Original msg")
}

// --- Outlook Mobile ---

func TestStripQuotedContent_OutlookMobile(t *testing.T) {
	html := `<p>Sent from iPhone</p><div class="ms-outlook-mobile-reference-message">Original</div>`
	assertStripped(t, "Outlook Mobile", html, "Sent from iPhone", "Original")
}

// --- Gmail ---

func TestStripQuotedContent_GmailQuote(t *testing.T) {
	html := `<p>Hi Alice,</p><div class="gmail_quote"><blockquote>Original email</blockquote></div>`
	assertStripped(t, "gmail_quote div", html, "Hi Alice", "Original email")
}

func TestStripQuotedContent_GmailExtra(t *testing.T) {
	html := `<p>My reply</p><div class="gmail_extra"><br>On Mon wrote:</div>`
	assertStripped(t, "gmail_extra div", html, "My reply", "On Mon wrote")
}

func TestStripQuotedContent_GmailBlockquoteClass(t *testing.T) {
	html := `<p>Thanks!</p><blockquote class="gmail_quote">Previous message</blockquote>`
	assertStripped(t, "gmail_quote blockquote", html, "Thanks", "Previous message")
}

// --- Apple Mail ---

func TestStripQuotedContent_AppleMail(t *testing.T) {
	html := `<p>Cool.</p><blockquote type="cite">Original Apple Mail text</blockquote>`
	assertStripped(t, "Apple Mail cite", html, "Cool", "Original Apple Mail text")
}

// --- Outlook Desktop (regex patterns) ---

func TestStripQuotedContent_OutlookDesktop_BorderTop(t *testing.T) {
	html := `<p>My reply.</p><div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0cm 0cm 0cm"><b>From:</b> Bob</div>`
	assertStripped(t, "Outlook Desktop border-top", html, "My reply", "Bob")
}

func TestStripQuotedContent_OutlookDesktop_BorderStyle(t *testing.T) {
	html := `<p>Reply</p><div style="padding:3.0pt 0cm 0cm 0cm;border-style:solid none none none"><b>From:</b> Alice</div>`
	assertStripped(t, "Outlook Desktop border-style", html, "Reply", "Alice")
}

func TestStripQuotedContent_OutlookHR_GermanVon(t *testing.T) {
	html := `<p>Hallo Bob,</p><hr><div><b>Von:</b> Alice</div>`
	assertStripped(t, "Outlook HR Von", html, "Hallo Bob", "Alice")
}

func TestStripQuotedContent_OutlookHR_EnglishFrom(t *testing.T) {
	html := `<p>Hi Bob</p><hr><div><b>From:</b> Alice</div>`
	assertStripped(t, "Outlook HR From", html, "Hi Bob", "Alice")
}

// --- Forwarded message separators ---

func TestStripQuotedContent_GermanForward(t *testing.T) {
	html := `<p>Schau mal:</p>---------- Urspr&uuml;ngliche Nachricht ----------<br>Original`
	assertStripped(t, "German forward separator", html, "Schau mal", "Original")
}

func TestStripQuotedContent_GermanForwardUTF8(t *testing.T) {
	html := `<p>Schau mal:</p>---------- Ursprüngliche Nachricht ----------<br>Original`
	assertStripped(t, "German forward separator (UTF-8)", html, "Schau mal", "Original")
}

func TestStripQuotedContent_EnglishForward(t *testing.T) {
	html := `<p>Check this:</p>---------- Original Message ----------<br>Content`
	assertStripped(t, "English forward separator", html, "Check this", "Content")
}

// --- Durian custom format ---

func TestStripQuotedContent_DurianFormat(t *testing.T) {
	html := `<p>Reply text</p><div style="color:#555;"><p>On Jan 1, Alice wrote:</p></div>`
	assertStripped(t, "Durian custom format", html, "Reply text", "Alice wrote")
}

// --- Earliest match wins ---

func TestStripQuotedContent_EarliestMatchWins(t *testing.T) {
	// Gmail quote before Apple Mail blockquote - should cut at Gmail
	html := `<p>My reply</p><div class="gmail_quote">Gmail quoted</div><blockquote type="cite">Apple quoted</blockquote>`
	result := StripQuotedContent(html)
	if strings.Contains(result, "Gmail quoted") {
		t.Error("should cut at earliest match (Gmail)")
	}
	if strings.Contains(result, "Apple quoted") {
		t.Error("should not contain content after earliest match")
	}
	if !strings.Contains(result, "My reply") {
		t.Error("should keep content before earliest match")
	}
}

// --- Generic blockquotes are NOT stripped ---

func TestStripQuotedContent_GenericBlockquoteKept(t *testing.T) {
	// A user includes a legitimate blockquote (e.g. a citation, code snippet).
	// Generic <blockquote> without quote-specific class should NOT be stripped.
	html := `<p>Here is a quote from a book:</p><blockquote>The only way to learn a new programming language is by writing programs in it.</blockquote><p>What do you think?</p>`
	result := StripQuotedContent(html)
	if !strings.Contains(result, "only way to learn") {
		t.Error("legitimate user blockquote should not be stripped")
	}
	if !strings.Contains(result, "What do you think") {
		t.Error("content after legitimate blockquote should not be stripped")
	}
}

// --- Mobile signature detection (real-world Outlook iOS forward bug) ---

func TestStripQuotedContent_OutlookMobileForwardWithSignature(t *testing.T) {
	// User forwards a mail via Outlook iOS — only the auto-signature
	// "Sent from Outlook for iOS" appears above the forward. The forward
	// content should NOT be lost.
	html := `<div><br></div><span>Sent from <a href="https://aka.ms/o0ukef">Outlook for iOS</a></span><div class="ms-outlook-mobile-reference-message"><hr><b>From:</b> Alice<br><b>Subject:</b> Important news<br><p>This is the forwarded content that must not be lost.</p></div>`
	result := StripQuotedContent(html)
	if !strings.Contains(result, "forwarded content that must not be lost") {
		t.Error("Outlook iOS forward with only mobile signature should keep forward content")
	}
}

func TestStripQuotedContent_iPhoneMailForward(t *testing.T) {
	html := `<div>Sent from my iPhone</div><blockquote class="gmail_quote"><p>Forwarded body here</p></blockquote>`
	result := StripQuotedContent(html)
	if !strings.Contains(result, "Forwarded body here") {
		t.Error("'Sent from my iPhone' alone should not cause forward to be stripped")
	}
}

func TestStripQuotedContent_GermaniPhoneForward(t *testing.T) {
	html := `<div>Von meinem iPhone gesendet</div><blockquote class="gmail_quote">Forwarded</blockquote>`
	result := StripQuotedContent(html)
	if !strings.Contains(result, "Forwarded") {
		t.Error("German iPhone signature should be detected as effectively empty")
	}
}

func TestStripQuotedContent_RealUserTextWithMobileSig(t *testing.T) {
	// User wrote actual text PLUS the signature — strip should still work
	html := `<p>Hi Alice, please see below.</p><div>Sent from my iPhone</div><blockquote class="gmail_quote">Original message</blockquote>`
	result := StripQuotedContent(html)
	if !strings.Contains(result, "Hi Alice") {
		t.Error("real user text should be kept")
	}
	if strings.Contains(result, "Original message") {
		t.Error("quoted content should still be stripped when user wrote real text")
	}
}

// --- Edge cases ---

func TestStripQuotedContent_WhitespaceTrimmed(t *testing.T) {
	html := `<p>Reply</p>
	<div class="gmail_quote">quoted</div>`
	result := StripQuotedContent(html)
	if strings.HasSuffix(result, " ") || strings.HasSuffix(result, "\n") || strings.HasSuffix(result, "\t") {
		t.Errorf("trailing whitespace should be trimmed, got: %q", result)
	}
}

func TestStripQuotedContent_CaseInsensitiveStringPatterns(t *testing.T) {
	html := `<p>Reply</p><DIV CLASS="gmail_quote">Original</DIV>`
	result := StripQuotedContent(html)
	if strings.Contains(result, "Original") {
		t.Error("string patterns should be case-insensitive")
	}
}

func TestStripQuotedContent_OnlyWhitespaceAboveQuote(t *testing.T) {
	// If there's only whitespace before the quote, keep the original
	html := `   <blockquote class="gmail_quote">Content</blockquote>`
	result := StripQuotedContent(html)
	if !strings.Contains(result, "Content") {
		t.Error("whitespace-only reply should keep original")
	}
}

// --- Multi-level forwards (current behavior: only first match) ---

func TestStripQuotedContent_MultiLevelForward(t *testing.T) {
	// Reply → forward 1 → forward 2
	// Current behavior: cuts at first forward, loses both
	// After fix: should still cut at first, but this documents current state
	html := `<p>My reply</p><div class="gmail_quote">First forward<div class="gmail_quote">Second forward</div></div>`
	result := StripQuotedContent(html)
	if strings.Contains(result, "First forward") {
		t.Error("should cut at first forward")
	}
	if !strings.Contains(result, "My reply") {
		t.Error("should keep reply")
	}
}

// --- isEmptyHTML ---

func TestIsEmptyHTML(t *testing.T) {
	cases := []struct {
		input string
		empty bool
	}{
		{"", true},
		{"   ", true},
		{"<p></p>", true},
		{"<p>  </p>", true},
		{"<br><br>", true},
		{"&nbsp;&nbsp;", true},
		{"<div><span></span></div>", true},
		{"<p>text</p>", false},
		{"Hello", false},
		{"<p>  x  </p>", false},
	}
	for _, tc := range cases {
		got := isEmptyHTML(tc.input)
		if got != tc.empty {
			t.Errorf("isEmptyHTML(%q) = %v, want %v", tc.input, got, tc.empty)
		}
	}
}

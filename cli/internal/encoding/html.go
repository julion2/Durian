package encoding

import (
	"fmt"
	"strings"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

// HTMLToText converts HTML content to plain text using golang.org/x/net/html.
func HTMLToText(s string) string {
	doc, err := html.Parse(strings.NewReader(s))
	if err != nil {
		return s
	}
	var buf strings.Builder
	extractText(&buf, doc)
	// Collapse runs of 3+ newlines into 2, trim trailing whitespace per line
	lines := strings.Split(buf.String(), "\n")
	var out []string
	blanks := 0
	for _, line := range lines {
		trimmed := strings.TrimRight(line, " \t")
		if trimmed == "" {
			blanks++
			if blanks <= 1 {
				out = append(out, "")
			}
		} else {
			blanks = 0
			out = append(out, trimmed)
		}
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}

// skipTags are elements whose entire subtree should be ignored.
var skipTags = map[atom.Atom]bool{
	atom.Script: true,
	atom.Style:  true,
	atom.Head:   true,
}

// blockTags are elements that get a newline before their content.
var blockTags = map[atom.Atom]bool{
	atom.P:          true,
	atom.Div:        true,
	atom.Br:         true,
	atom.H1:         true,
	atom.H2:         true,
	atom.H3:         true,
	atom.H4:         true,
	atom.H5:         true,
	atom.H6:         true,
	atom.Li:         true,
	atom.Tr:         true,
	atom.Blockquote: true,
	atom.Pre:        true,
	atom.Hr:         true,
	atom.Table:      true,
}

func extractText(buf *strings.Builder, n *html.Node) {
	if n.Type == html.ElementNode {
		if skipTags[n.DataAtom] {
			return
		}
		if blockTags[n.DataAtom] {
			buf.WriteString("\n")
		}
		if n.DataAtom == atom.Td || n.DataAtom == atom.Th {
			buf.WriteString("\t")
		}
	}

	if n.Type == html.TextNode {
		buf.WriteString(n.Data)
	}

	for c := n.FirstChild; c != nil; c = c.NextSibling {
		extractText(buf, c)
	}

	// Post-element handling
	if n.Type == html.ElementNode {
		if n.DataAtom == atom.A {
			href := getAttr(n, "href")
			if href != "" && !strings.HasPrefix(href, "#") {
				fmt.Fprintf(buf, " (%s)", href)
			}
		}
		if blockTags[n.DataAtom] && n.DataAtom != atom.Br {
			buf.WriteString("\n")
		}
	}
}

func getAttr(n *html.Node, key string) string {
	for _, a := range n.Attr {
		if a.Key == key {
			return a.Val
		}
	}
	return ""
}

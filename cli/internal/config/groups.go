package config

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/BurntSushi/toml"
)

// GroupEntry defines a single contact group.
// Members is a list of people, where each person can have multiple addresses.
// Example: [["alice@work.com", "alice@gmail.com"], ["bob@vc.com"], ["*@fund.com"]]
type GroupEntry struct {
	Description string     `toml:"description"`
	Members     [][]string `toml:"members"`
}

// groupsFile is the top-level structure of groups.toml.
type groupsFile struct {
	Groups map[string]GroupEntry `toml:"groups"`
}

// LoadGroups loads contact groups from the given path.
// Returns nil if the file doesn't exist.
func LoadGroups(path string) (map[string]GroupEntry, error) {
	if path == "" {
		path = GroupsPath()
	}
	path = ExpandPath(path)

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	}

	var f groupsFile
	if _, err := toml.DecodeFile(path, &f); err != nil {
		return nil, fmt.Errorf("failed to load groups: %w", err)
	}

	return f.Groups, nil
}

// GroupsPath returns the default groups.toml path.
func GroupsPath() string {
	return filepath.Join(filepath.Dir(DefaultPath()), "groups.toml")
}

// groupRef matches group:name and group:name/modifier tokens in a query string.
// Supported modifiers: /from, /to. Default (no modifier) expands both directions.
var groupRef = regexp.MustCompile(`\bgroup:([a-zA-Z0-9_-]+)(?:/(from|to))?`)

// ExpandGroupsInQuery replaces all group:NAME references in a query string
// with equivalent address expressions.
//
// Default (bidirectional): group:X → (from:a OR to:a OR from:b OR to:b ...)
// Directed: group:X/from → (from:a OR from:b ...) — only incoming
//
//	group:X/to   → (to:a OR to:b ...)   — only outgoing
//
// Wildcard members (*@domain.com) expand to @domain.com which matches
// via the existing LIKE '%@domain.com%' SQL pattern.
func ExpandGroupsInQuery(query string, groups map[string]GroupEntry) (string, error) {
	if len(groups) == 0 {
		return query, nil
	}

	var expandErr error
	result := groupRef.ReplaceAllStringFunc(query, func(match string) string {
		if expandErr != nil {
			return match
		}

		sub := groupRef.FindStringSubmatch(match)
		name := sub[1]
		modifier := sub[2] // "", "from", or "to"

		group, ok := groups[name]
		if !ok {
			expandErr = fmt.Errorf("unknown group: %q", name)
			return match
		}
		if len(group.Members) == 0 {
			expandErr = fmt.Errorf("group %q has no members", name)
			return match
		}

		var parts []string
		for _, person := range group.Members {
			for _, addr := range person {
				// Strip wildcard prefix for LIKE matching
				a := addr
				if strings.HasPrefix(a, "*") {
					a = a[1:]
				}
				parts = append(parts, expandAddr(a, modifier)...)
			}
		}

		if len(parts) == 1 {
			return parts[0]
		}
		return "(" + strings.Join(parts, " OR ") + ")"
	})

	if expandErr != nil {
		return "", expandErr
	}
	return result, nil
}

// expandAddr returns the from:/to: terms for a single address based on modifier.
func expandAddr(addr, modifier string) []string {
	switch modifier {
	case "from":
		return []string{"from:" + addr}
	case "to":
		return []string{"to:" + addr}
	default:
		return []string{"from:" + addr, "to:" + addr}
	}
}

// ValidateGroups validates groups.toml entries.
func ValidateGroups(groups map[string]GroupEntry) []ValidationError {
	var errs []ValidationError
	add := func(field, msg string) {
		errs = append(errs, ValidationError{File: "groups.toml", Field: field, Message: msg, Severity: "error"})
	}
	warn := func(field, msg string) {
		errs = append(errs, ValidationError{File: "groups.toml", Field: field, Message: msg, Severity: "warning"})
	}

	for name, group := range groups {
		prefix := "groups." + name

		if len(group.Members) == 0 {
			warn(prefix+".members", "group has no members")
			continue
		}

		for i, person := range group.Members {
			if len(person) == 0 {
				add(fmt.Sprintf("%s.members[%d]", prefix, i), "empty member entry")
				continue
			}
			for j, addr := range person {
				field := fmt.Sprintf("%s.members[%d][%d]", prefix, i, j)
				if addr == "" {
					add(field, "empty address")
					continue
				}
				if strings.HasPrefix(addr, "*@") {
					domain := addr[2:]
					if !strings.Contains(domain, ".") {
						warn(field, fmt.Sprintf("domain wildcard %q has no dot — may match too broadly", addr))
					}
				} else if strings.HasPrefix(addr, "*") {
					add(field, fmt.Sprintf("invalid wildcard pattern %q (only *@domain is supported)", addr))
				} else if !strings.Contains(addr, "@") {
					add(field, fmt.Sprintf("invalid address %q (expected email or *@domain)", addr))
				}
			}
		}
	}

	return errs
}

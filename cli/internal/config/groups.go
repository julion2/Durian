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
type GroupEntry struct {
	Description string   `toml:"description"`
	Members     []string `toml:"members"`
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

// groupRef matches group:name tokens in a query string.
var groupRef = regexp.MustCompile(`\bgroup:([a-zA-Z0-9_-]+)`)

// ExpandGroupsInQuery replaces all group:NAME references in a query string
// with equivalent (from:member1 OR from:member2 ...) expressions.
// Wildcard members (*@domain.com) are expanded to from:@domain.com
// which matches via the existing LIKE '%@domain.com%' SQL pattern.
func ExpandGroupsInQuery(query string, groups map[string]GroupEntry) (string, error) {
	if len(groups) == 0 {
		return query, nil
	}

	var expandErr error
	result := groupRef.ReplaceAllStringFunc(query, func(match string) string {
		if expandErr != nil {
			return match
		}
		name := match[len("group:"):]
		group, ok := groups[name]
		if !ok {
			expandErr = fmt.Errorf("unknown group: %q", name)
			return match
		}
		if len(group.Members) == 0 {
			expandErr = fmt.Errorf("group %q has no members", name)
			return match
		}

		parts := make([]string, len(group.Members))
		for i, member := range group.Members {
			if strings.HasPrefix(member, "*") {
				// Wildcard: *@domain.com → from:@domain.com
				parts[i] = "from:" + member[1:]
			} else {
				parts[i] = "from:" + member
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

		for i, member := range group.Members {
			field := fmt.Sprintf("%s.members[%d]", prefix, i)
			if member == "" {
				add(field, "empty member entry")
				continue
			}
			if strings.HasPrefix(member, "*@") {
				// Domain wildcard — check domain part
				domain := member[2:]
				if !strings.Contains(domain, ".") {
					warn(field, fmt.Sprintf("domain wildcard %q has no dot — may match too broadly", member))
				}
			} else if strings.HasPrefix(member, "*") {
				add(field, fmt.Sprintf("invalid wildcard pattern %q (only *@domain is supported)", member))
			} else if !strings.Contains(member, "@") {
				add(field, fmt.Sprintf("invalid member %q (expected email or *@domain)", member))
			}
		}
	}

	return errs
}

package config

import (
	"testing"
)

func TestLoadGroups(t *testing.T) {
	groups, err := LoadGroups("testdata/valid_groups.toml")
	if err != nil {
		t.Fatalf("LoadGroups() error: %v", err)
	}

	if len(groups) != 4 {
		t.Fatalf("got %d groups, want 4", len(groups))
	}

	inv := groups["investor"]
	if inv.Description != "Cap Table members" {
		t.Errorf("investor.Description = %q, want %q", inv.Description, "Cap Table members")
	}
	if len(inv.Members) != 3 {
		t.Errorf("investor.Members count = %d, want 3", len(inv.Members))
	}
	// First member has two addresses
	if len(inv.Members[0]) != 2 {
		t.Errorf("investor.Members[0] addresses = %d, want 2", len(inv.Members[0]))
	}
}

func TestLoadGroups_NotFound(t *testing.T) {
	groups, err := LoadGroups("testdata/nonexistent_groups.toml")
	if err != nil {
		t.Fatalf("LoadGroups() error: %v", err)
	}
	if groups != nil {
		t.Errorf("expected nil for missing file, got %v", groups)
	}
}

func TestExpandGroupsInQuery(t *testing.T) {
	groups := map[string]GroupEntry{
		"investor": {Members: [][]string{
			{"alice@sequoia.com"},
			{"bob@index.vc"},
		}},
		"press": {Members: [][]string{
			{"*@spiegel.de"},
			{"*@handelsblatt.com"},
		}},
		"solo": {Members: [][]string{
			{"carol@example.org"},
		}},
		"multi": {Members: [][]string{
			{"alice@work.com", "alice@gmail.com"},
		}},
	}

	tests := []struct {
		name    string
		query   string
		want    string
		wantErr bool
	}{
		{
			name:  "bidirectional default — two members",
			query: "group:investor",
			want:  "(from:alice@sequoia.com OR to:alice@sequoia.com OR from:bob@index.vc OR to:bob@index.vc)",
		},
		{
			name:  "domain wildcards — bidirectional",
			query: "group:press",
			want:  "(from:@spiegel.de OR to:@spiegel.de OR from:@handelsblatt.com OR to:@handelsblatt.com)",
		},
		{
			name:  "single member — no parens",
			query: "group:solo",
			want:  "(from:carol@example.org OR to:carol@example.org)",
		},
		{
			name:  "modifier /from — incoming only",
			query: "group:investor/from",
			want:  "(from:alice@sequoia.com OR from:bob@index.vc)",
		},
		{
			name:  "modifier /to — outgoing only",
			query: "group:investor/to",
			want:  "(to:alice@sequoia.com OR to:bob@index.vc)",
		},
		{
			name:  "multi-email person — all addresses expanded",
			query: "group:multi",
			want:  "(from:alice@work.com OR to:alice@work.com OR from:alice@gmail.com OR to:alice@gmail.com)",
		},
		{
			name:  "multi-email with /from modifier",
			query: "group:multi/from",
			want:  "(from:alice@work.com OR from:alice@gmail.com)",
		},
		{
			name:  "group with AND clause",
			query: "group:investor AND date:month",
			want:  "(from:alice@sequoia.com OR to:alice@sequoia.com OR from:bob@index.vc OR to:bob@index.vc) AND date:month",
		},
		{
			name:  "multiple groups in query",
			query: "group:investor/from OR group:press/from",
			want:  "(from:alice@sequoia.com OR from:bob@index.vc) OR (from:@spiegel.de OR from:@handelsblatt.com)",
		},
		{
			name:  "no group reference — passthrough",
			query: "from:alice tag:inbox",
			want:  "from:alice tag:inbox",
		},
		{
			name:  "empty query — passthrough",
			query: "",
			want:  "",
		},
		{
			name:  "star query — passthrough",
			query: "*",
			want:  "*",
		},
		{
			name:    "unknown group — error",
			query:   "group:unknown",
			wantErr: true,
		},
		{
			name:  "sent review pattern",
			query: "group:investor/to AND tag:sent AND date:week",
			want:  "(to:alice@sequoia.com OR to:bob@index.vc) AND tag:sent AND date:week",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ExpandGroupsInQuery(tt.query, groups)
			if tt.wantErr {
				if err == nil {
					t.Error("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Errorf("ExpandGroupsInQuery(%q)\n  got  %q\n  want %q", tt.query, got, tt.want)
			}
		})
	}
}

func TestExpandGroupsInQuery_NilGroups(t *testing.T) {
	got, err := ExpandGroupsInQuery("group:anything", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "group:anything" {
		t.Errorf("expected passthrough, got %q", got)
	}
}

func TestValidateGroups(t *testing.T) {
	tests := []struct {
		name      string
		groups    map[string]GroupEntry
		wantErrs  int
		wantWarns int
	}{
		{
			name: "valid groups",
			groups: map[string]GroupEntry{
				"investor": {Members: [][]string{{"alice@vc.com"}, {"*@fund.com"}}},
			},
			wantErrs:  0,
			wantWarns: 0,
		},
		{
			name: "multi-email valid",
			groups: map[string]GroupEntry{
				"multi": {Members: [][]string{{"alice@work.com", "alice@gmail.com"}}},
			},
			wantErrs:  0,
			wantWarns: 0,
		},
		{
			name: "empty members — warning",
			groups: map[string]GroupEntry{
				"empty": {Members: [][]string{}},
			},
			wantErrs:  0,
			wantWarns: 1,
		},
		{
			name: "invalid member — no @",
			groups: map[string]GroupEntry{
				"bad": {Members: [][]string{{"notanemail"}}},
			},
			wantErrs: 1,
		},
		{
			name: "invalid wildcard pattern",
			groups: map[string]GroupEntry{
				"bad": {Members: [][]string{{"*notdomain"}}},
			},
			wantErrs: 1,
		},
		{
			name: "domain wildcard without dot — warning",
			groups: map[string]GroupEntry{
				"broad": {Members: [][]string{{"*@localhost"}}},
			},
			wantWarns: 1,
		},
		{
			name: "empty person array — error",
			groups: map[string]GroupEntry{
				"bad": {Members: [][]string{{}}},
			},
			wantErrs: 1,
		},
		{
			name: "empty address string — error",
			groups: map[string]GroupEntry{
				"bad": {Members: [][]string{{""}}},
			},
			wantErrs: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			errs := ValidateGroups(tt.groups)
			errors := 0
			warnings := 0
			for _, e := range errs {
				if e.Severity == "error" {
					errors++
				} else {
					warnings++
				}
			}
			if errors != tt.wantErrs {
				t.Errorf("errors = %d, want %d (errs: %v)", errors, tt.wantErrs, errs)
			}
			if tt.wantWarns > 0 && warnings != tt.wantWarns {
				t.Errorf("warnings = %d, want %d (errs: %v)", warnings, tt.wantWarns, errs)
			}
		})
	}
}

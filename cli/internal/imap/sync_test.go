package imap

import (
	"testing"
)

func TestMatchMailbox(t *testing.T) {
	tests := []struct {
		name     string
		mailbox  string
		pattern  string
		expected bool
	}{
		// Exact matches
		{
			name:     "exact match INBOX",
			mailbox:  "INBOX",
			pattern:  "INBOX",
			expected: true,
		},
		{
			name:     "exact match case insensitive",
			mailbox:  "inbox",
			pattern:  "INBOX",
			expected: true,
		},
		{
			name:     "exact match Sent",
			mailbox:  "Sent",
			pattern:  "Sent",
			expected: true,
		},

		// Prefix matches
		{
			name:     "prefix match Sent Items",
			mailbox:  "Sent Items",
			pattern:  "Sent",
			expected: true,
		},
		{
			name:     "prefix match Sent Messages",
			mailbox:  "Sent Messages",
			pattern:  "Sent",
			expected: true,
		},
		{
			name:     "prefix match case insensitive",
			mailbox:  "SENT ITEMS",
			pattern:  "sent",
			expected: true,
		},
		{
			name:     "prefix match Drafts subfolder",
			mailbox:  "Drafts/Important",
			pattern:  "Drafts",
			expected: true,
		},

		// No match
		{
			name:     "no match different names",
			mailbox:  "Archive",
			pattern:  "Sent",
			expected: false,
		},
		{
			name:     "no match partial in middle",
			mailbox:  "My Sent Folder",
			pattern:  "Sent",
			expected: false,
		},
		{
			name:     "no match suffix",
			mailbox:  "NotSent",
			pattern:  "Sent",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := matchMailbox(tt.mailbox, tt.pattern)
			if got != tt.expected {
				t.Errorf("matchMailbox(%q, %q) = %v, want %v",
					tt.mailbox, tt.pattern, got, tt.expected)
			}
		})
	}
}

func TestSyncOptions_Defaults(t *testing.T) {
	// Test nil options handling
	opts := &SyncOptions{}

	if opts.DryRun {
		t.Error("expected DryRun to be false by default")
	}

	if opts.Quiet {
		t.Error("expected Quiet to be false by default")
	}

	if opts.NoNotmuch {
		t.Error("expected NoNotmuch to be false by default")
	}

	if len(opts.Mailboxes) != 0 {
		t.Error("expected Mailboxes to be empty by default")
	}
}

func TestSyncResult_Aggregation(t *testing.T) {
	result := &SyncResult{
		Account: "test@example.com",
	}

	// Add mailbox results
	result.Mailboxes = append(result.Mailboxes, MailboxResult{
		Name:        "INBOX",
		TotalMsgs:   100,
		NewMsgs:     5,
		SkippedMsgs: 1,
	})

	result.Mailboxes = append(result.Mailboxes, MailboxResult{
		Name:        "Sent",
		TotalMsgs:   50,
		NewMsgs:     3,
		SkippedMsgs: 0,
	})

	// Aggregate
	for _, mb := range result.Mailboxes {
		result.TotalNew += mb.NewMsgs
		result.TotalSkipped += mb.SkippedMsgs
	}

	if result.TotalNew != 8 {
		t.Errorf("expected TotalNew 8, got %d", result.TotalNew)
	}

	if result.TotalSkipped != 1 {
		t.Errorf("expected TotalSkipped 1, got %d", result.TotalSkipped)
	}
}

func TestBatchSplitting(t *testing.T) {
	tests := []struct {
		name          string
		totalUIDs     int
		batchSize     int
		expectedBatch int
	}{
		{
			name:          "exact batch",
			totalUIDs:     100,
			batchSize:     100,
			expectedBatch: 1,
		},
		{
			name:          "multiple batches",
			totalUIDs:     250,
			batchSize:     100,
			expectedBatch: 3,
		},
		{
			name:          "single item",
			totalUIDs:     1,
			batchSize:     100,
			expectedBatch: 1,
		},
		{
			name:          "empty",
			totalUIDs:     0,
			batchSize:     100,
			expectedBatch: 0,
		},
		{
			name:          "large batch size",
			totalUIDs:     50,
			batchSize:     5000,
			expectedBatch: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate batch calculation
			var batchCount int
			if tt.totalUIDs > 0 {
				batchCount = (tt.totalUIDs + tt.batchSize - 1) / tt.batchSize
			}

			if batchCount != tt.expectedBatch {
				t.Errorf("expected %d batches, got %d", tt.expectedBatch, batchCount)
			}

			// Verify all items are covered
			totalProcessed := 0
			for i := 0; i < tt.totalUIDs; i += tt.batchSize {
				end := i + tt.batchSize
				if end > tt.totalUIDs {
					end = tt.totalUIDs
				}
				totalProcessed += end - i
			}

			if totalProcessed != tt.totalUIDs {
				t.Errorf("expected to process %d items, processed %d", tt.totalUIDs, totalProcessed)
			}
		})
	}
}

func TestMailboxResult(t *testing.T) {
	result := MailboxResult{
		Name:        "INBOX",
		TotalMsgs:   100,
		NewMsgs:     10,
		SkippedMsgs: 2,
		Error:       nil,
	}

	if result.Name != "INBOX" {
		t.Errorf("expected Name INBOX, got %s", result.Name)
	}

	if result.TotalMsgs != 100 {
		t.Errorf("expected TotalMsgs 100, got %d", result.TotalMsgs)
	}

	if result.NewMsgs != 10 {
		t.Errorf("expected NewMsgs 10, got %d", result.NewMsgs)
	}

	if result.SkippedMsgs != 2 {
		t.Errorf("expected SkippedMsgs 2, got %d", result.SkippedMsgs)
	}

	if result.Error != nil {
		t.Error("expected Error to be nil")
	}
}

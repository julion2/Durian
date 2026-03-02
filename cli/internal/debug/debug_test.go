package debug

import (
	"bytes"
	"fmt"
	"os"
	"sync"
	"testing"
)

func TestSetEnabled(t *testing.T) {
	// Default should be false
	SetEnabled(false)
	if IsEnabled() {
		t.Error("expected disabled by default")
	}

	SetEnabled(true)
	if !IsEnabled() {
		t.Error("expected enabled after SetEnabled(true)")
	}

	SetEnabled(false)
	if IsEnabled() {
		t.Error("expected disabled after SetEnabled(false)")
	}
}

func TestLog_Enabled(t *testing.T) {
	// Capture stderr
	oldStderr := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w

	SetEnabled(true)
	Log("hello %s", "world")

	w.Close()
	os.Stderr = oldStderr

	var buf bytes.Buffer
	buf.ReadFrom(r)
	output := buf.String()

	if output != "[DEBUG] hello world\n" {
		t.Errorf("expected '[DEBUG] hello world\\n', got %q", output)
	}
}

func TestLog_Disabled(t *testing.T) {
	oldStderr := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w

	SetEnabled(false)
	Log("should not appear")

	w.Close()
	os.Stderr = oldStderr

	var buf bytes.Buffer
	buf.ReadFrom(r)
	output := buf.String()

	if output != "" {
		t.Errorf("expected no output when disabled, got %q", output)
	}
}

func TestConcurrentAccess(t *testing.T) {
	// This test is designed to be run with -race to verify no data race.
	var wg sync.WaitGroup

	// Suppress stderr output during concurrent test
	oldStderr := os.Stderr
	devNull, _ := os.Open(os.DevNull)
	os.Stderr = devNull
	defer func() {
		os.Stderr = oldStderr
		devNull.Close()
	}()

	for i := 0; i < 100; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			SetEnabled(true)
		}()
		go func(n int) {
			defer wg.Done()
			Log("concurrent log %d", n)
		}(i)
	}

	wg.Wait()
	// If we get here without -race detecting anything, the test passes.
	// Reset state.
	SetEnabled(false)
}

func TestLog_FormatVariants(t *testing.T) {
	SetEnabled(true)
	defer SetEnabled(false)

	oldStderr := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w

	Log("count: %d, name: %s", 42, "test")

	w.Close()
	os.Stderr = oldStderr

	var buf bytes.Buffer
	buf.ReadFrom(r)

	expected := fmt.Sprintf("[DEBUG] count: %d, name: %s\n", 42, "test")
	if buf.String() != expected {
		t.Errorf("got %q, want %q", buf.String(), expected)
	}
}

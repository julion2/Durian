// Package debug provides simple debug logging functionality.
// Enable via the --debug flag on any durian command.
package debug

import (
	"fmt"
	"os"
	"sync/atomic"
)

// enabled controls whether debug output is shown.
// Set to true via the --debug flag.
var enabled atomic.Bool

// SetEnabled sets whether debug logging is enabled.
func SetEnabled(v bool) {
	enabled.Store(v)
}

// IsEnabled returns whether debug logging is enabled.
func IsEnabled() bool {
	return enabled.Load()
}

// Log prints a debug message to stderr if debug mode is enabled.
// Format follows fmt.Printf conventions.
func Log(format string, args ...interface{}) {
	if enabled.Load() {
		fmt.Fprintf(os.Stderr, "[DEBUG] "+format+"\n", args...)
	}
}

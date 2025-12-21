// Package debug provides simple debug logging functionality.
// Enable via the --debug flag on any durian command.
package debug

import (
	"fmt"
	"os"
)

// Enabled controls whether debug output is shown.
// Set to true via the --debug flag.
var Enabled bool

// Log prints a debug message to stderr if debug mode is enabled.
// Format follows fmt.Printf conventions.
func Log(format string, args ...interface{}) {
	if Enabled {
		fmt.Fprintf(os.Stderr, "[DEBUG] "+format+"\n", args...)
	}
}

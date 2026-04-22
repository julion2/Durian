package config

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// evalFunc is the function used to evaluate config files into JSON.
// Defaults to pklEval but can be overridden in tests.
var evalFunc = pklEval

// pklEval evaluates a .pkl file and returns its JSON representation.
// Requires the pkl CLI to be installed (brew install pkl).
func pklEval(path string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "pkl", "eval", "--format", "json", path)
	out, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("pkl eval failed: %s", string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("pkl eval failed: %w", err)
	}
	return out, nil
}

// evalConfigFile evaluates a config file into JSON.
// For .json files (used in tests), reads directly. For .pkl files, uses pkl eval.
func evalConfigFile(path string) ([]byte, error) {
	if strings.HasSuffix(path, ".json") {
		return os.ReadFile(path)
	}
	return evalFunc(path)
}

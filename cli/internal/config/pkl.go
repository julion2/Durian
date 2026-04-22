package config

import (
	"context"
	"embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

//go:embed schema/*.pkl
var schemaFS embed.FS

// schemaDir holds the temp directory with extracted schemas (created once).
var (
	schemaDir     string
	schemaDirOnce sync.Once
)

// getSchemaDir extracts embedded .pkl schemas to a temp dir (once per process).
func getSchemaDir() string {
	schemaDirOnce.Do(func() {
		dir, err := os.MkdirTemp("", "durian-schema-*")
		if err != nil {
			return
		}

		entries, err := schemaFS.ReadDir("schema")
		if err != nil {
			return
		}

		for _, e := range entries {
			data, err := schemaFS.ReadFile("schema/" + e.Name())
			if err != nil {
				continue
			}
			_ = os.WriteFile(filepath.Join(dir, e.Name()), data, 0644)
		}

		schemaDir = dir
	})
	return schemaDir
}

// evalFunc is the function used to evaluate config files into JSON.
// Defaults to pklEval but can be overridden in tests.
var evalFunc = pklEval

// pklEval evaluates a .pkl file and returns its JSON representation.
// Requires the pkl CLI to be installed (brew install pkl).
func pklEval(path string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	args := []string{"eval", "--format", "json"}
	if sd := getSchemaDir(); sd != "" {
		args = append(args, "--module-path", sd, "--allowed-modules", "file:,modulepath:")
	}
	args = append(args, path)

	cmd := exec.CommandContext(ctx, "pkl", args...)
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

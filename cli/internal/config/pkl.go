package config

import (
	"context"
	"embed"
	"encoding/json"
	"io/fs"
	"os"
	"strings"

	"github.com/apple/pkl-go/pkl"
)

//go:embed schema/*.pkl
var schemaFS embed.FS

// pklLoad evaluates a .pkl file directly into a Go struct via pkl-go.
// Schemas are served from embedded FS via the modulepath: scheme.
func pklLoad(path string, out any) error {
	subFS, err := fs.Sub(schemaFS, "schema")
	if err != nil {
		return err
	}

	ctx := context.Background()
	evaluator, err := pkl.NewEvaluator(ctx,
		pkl.PreconfiguredOptions,
		pkl.WithFs(subFS, "modulepath"),
	)
	if err != nil {
		return err
	}
	defer evaluator.Close()

	return evaluator.EvaluateModule(ctx, pkl.FileSource(path), out)
}

// loadInto evaluates a config file into the given struct.
// .json files (tests): json.Unmarshal. .pkl files: pkl-go direct evaluation.
func loadInto(path string, out any) error {
	if strings.HasSuffix(path, ".json") {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return json.Unmarshal(data, out)
	}
	return pklLoad(path, out)
}

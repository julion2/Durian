.PHONY: build install clean test

# Default target
all: install

# Build the CLI binary in cli/ directory
build:
	cd cli && go build -o durian ./cmd/durian

# Build and install to ~/.local/bin
install:
	cd cli && go build -o ~/.local/bin/durian ./cmd/durian
	@echo "✅ durian installed to ~/.local/bin/durian"

# Run tests
test:
	cd cli && go test ./...

# Clean build artifacts
clean:
	rm -f cli/durian
	@echo "✅ Cleaned build artifacts"

# Run go mod tidy
tidy:
	cd cli && go mod tidy

# Build for development (with race detector)
dev:
	cd cli && go build -race -o durian ./cmd/durian

.PHONY: build install clean test

# Version from git tags, or "dev" if not available
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# Default target
all: install

# Build the CLI binary in cli/ directory
build:
	cd cli && go build -ldflags "-X main.version=$(VERSION)" -o durian ./cmd/durian

# Build and install to ~/.local/bin
install:
	cd cli && go build -ldflags "-X main.version=$(VERSION)" -o ~/.local/bin/durian ./cmd/durian
	@echo "✅ durian $(VERSION) installed to ~/.local/bin/durian"

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
	cd cli && go build -race -ldflags "-X main.version=$(VERSION)-dev" -o durian ./cmd/durian

# Show version that would be used
version:
	@echo $(VERSION)

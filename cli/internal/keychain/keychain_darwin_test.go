package keychain

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"testing"
)

// TestHelperProcess is not a real test — it is invoked as a subprocess by
// tests that override commandRunner to simulate security CLI responses.
func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_TEST_HELPER") != "1" {
		return
	}
	switch os.Getenv("GO_TEST_MODE") {
	case "success":
		fmt.Fprint(os.Stdout, os.Getenv("GO_TEST_STDOUT"))
		os.Exit(0)
	case "exit44":
		os.Exit(44)
	case "exit1":
		fmt.Fprint(os.Stderr, os.Getenv("GO_TEST_STDERR"))
		os.Exit(1)
	default:
		fmt.Fprintln(os.Stderr, "unknown GO_TEST_MODE")
		os.Exit(2)
	}
}

// mockCommand returns a commandRunner replacement that invokes TestHelperProcess
// with the given mode, stdout, and stderr values.
func mockCommand(mode, stdout, stderr string) func(string, ...string) *exec.Cmd {
	return func(name string, args ...string) *exec.Cmd {
		cmd := exec.Command(os.Args[0], "-test.run=TestHelperProcess")
		cmd.Env = append(os.Environ(),
			"GO_TEST_HELPER=1",
			"GO_TEST_MODE="+mode,
			"GO_TEST_STDOUT="+stdout,
			"GO_TEST_STDERR="+stderr,
		)
		return cmd
	}
}

func restoreCommandRunner() { commandRunner = exec.Command }

// --- GetPassword ---

func TestGetPassword_Success(t *testing.T) {
	commandRunner = mockCommand("success", "my-secret\n", "")
	defer restoreCommandRunner()

	pw, err := GetPassword("svc", "acct")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if pw != "my-secret" {
		t.Errorf("password = %q, want %q", pw, "my-secret")
	}
}

func TestGetPassword_NotFound(t *testing.T) {
	commandRunner = mockCommand("exit44", "", "")
	defer restoreCommandRunner()

	_, err := GetPassword("svc", "acct")
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v, want ErrNotFound", err)
	}
}

func TestGetPassword_ExecError(t *testing.T) {
	commandRunner = mockCommand("exit1", "", "security: something went wrong")
	defer restoreCommandRunner()

	_, err := GetPassword("svc", "acct")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if errors.Is(err, ErrNotFound) {
		t.Error("should not be ErrNotFound")
	}
}

// --- SetPassword ---

func TestSetPassword_Success(t *testing.T) {
	commandRunner = mockCommand("success", "", "")
	defer restoreCommandRunner()

	err := SetPassword("svc", "acct", "pw")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSetPassword_Failure(t *testing.T) {
	commandRunner = mockCommand("exit1", "", "add failed")
	defer restoreCommandRunner()

	err := SetPassword("svc", "acct", "pw")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

// --- DeletePassword ---

func TestDeletePassword_Success(t *testing.T) {
	commandRunner = mockCommand("success", "", "")
	defer restoreCommandRunner()

	err := DeletePassword("svc", "acct")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDeletePassword_NotFoundIsNil(t *testing.T) {
	commandRunner = mockCommand("exit44", "", "")
	defer restoreCommandRunner()

	err := DeletePassword("svc", "acct")
	if err != nil {
		t.Errorf("expected nil for not-found, got: %v", err)
	}
}

func TestDeletePassword_OtherError(t *testing.T) {
	commandRunner = mockCommand("exit1", "", "delete failed")
	defer restoreCommandRunner()

	err := DeletePassword("svc", "acct")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

// --- Exists ---

func TestExists_Found(t *testing.T) {
	commandRunner = mockCommand("success", "pw\n", "")
	defer restoreCommandRunner()

	if !Exists("svc", "acct") {
		t.Error("Exists() = false, want true")
	}
}

func TestExists_NotFound(t *testing.T) {
	commandRunner = mockCommand("exit44", "", "")
	defer restoreCommandRunner()

	if Exists("svc", "acct") {
		t.Error("Exists() = true, want false")
	}
}

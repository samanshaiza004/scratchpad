package phase0

import (
	"context"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestPTYShellSmoke(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Phase 0 PTY smoke uses POSIX shell control characters")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	session, err := StartSession(ctx, SessionOptions{
		Shell: "/bin/sh",
		Dir:   t.TempDir(),
		Cols:  80,
		Rows:  24,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = session.Close() }()
	if err := session.Resize(100, 30, 9, 18); err != nil {
		_ = session.Close()
		t.Fatalf("resize shell session: %v", err)
	}
	if snapshot := session.Snapshot(); snapshot.Cols != 100 || snapshot.Rows != 30 {
		_ = session.Close()
		t.Fatalf("resized dimensions = %dx%d, want 100x30", snapshot.Cols, snapshot.Rows)
	}

	if _, err := session.WriteInput([]byte("printf 'phase0-shell-ok\\n'; sleep 30\n")); err != nil {
		_ = session.Close()
		t.Fatal(err)
	}
	if !waitForOutput(session, "phase0-shell-ok", 2*time.Second) {
		t.Fatalf("shell output did not arrive; final screen = %q", session.Snapshot().PlainText())
	}
	// The sleep is foreground in the interactive shell. The terminal line
	// discipline should turn this byte into SIGINT for that process group.
	time.Sleep(100 * time.Millisecond)
	if _, err := session.WriteInput([]byte{3}); err != nil {
		t.Fatal(err)
	}
	if _, err := session.WriteInput([]byte("printf 'phase0-ctrl-c-ok\\n'; exit\n")); err != nil {
		t.Fatal(err)
	}
	if !waitForOutput(session, "phase0-ctrl-c-ok", 2*time.Second) {
		t.Fatalf("Ctrl-C did not return control to shell; final screen = %q", session.Snapshot().PlainText())
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
}

func waitForOutput(session *Session, want string, timeout time.Duration) bool {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		if strings.Contains(session.Snapshot().PlainText(), want) {
			return true
		}
		select {
		case <-deadline.C:
			return false
		case <-tick.C:
		}
	}
}

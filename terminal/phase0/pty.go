package phase0

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"

	pty "github.com/aymanbagabas/go-pty"
)

// PTY is the small process boundary the eventual Scratchpad session will own.
// Concrete go-pty values never leave this package.
type PTY interface {
	io.ReadWriteCloser
	Resize(cols, rows int) error
}

type ptyHandle struct {
	pty.Pty
	writeMu sync.Mutex
}

var _ PTY = (*ptyHandle)(nil)

func (p *ptyHandle) Resize(cols, rows int) error {
	return p.Pty.Resize(cols, rows)
}

func (p *ptyHandle) Write(data []byte) (int, error) {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	return p.Pty.Write(data)
}

// SessionOptions controls the Phase 0 shell smoke. It intentionally has no
// profiles, tabs, tasks, or workbench state.
type SessionOptions struct {
	Shell string
	Dir   string
	Env   []string
	Cols  uint16
	Rows  uint16
}

func (o SessionOptions) withDefaults() SessionOptions {
	if o.Cols == 0 {
		o.Cols = DefaultCols
	}
	if o.Rows == 0 {
		o.Rows = DefaultRows
	}
	if o.Dir == "" {
		o.Dir, _ = os.Getwd()
	}
	if o.Shell == "" {
		o.Shell = defaultShell()
	}
	if o.Env == nil {
		o.Env = append([]string(nil), os.Environ()...)
	}
	o.Env = withEnv(o.Env, "TERM", "xterm-256color")
	return o
}

func withEnv(env []string, key, value string) []string {
	prefix := key + "="
	result := append([]string(nil), env...)
	for i, item := range result {
		if len(item) >= len(prefix) && item[:len(prefix)] == prefix {
			result[i] = prefix + value
			return result
		}
	}
	return append(result, prefix+value)
}

func defaultShell() string {
	if runtime.GOOS == "windows" {
		if shell := os.Getenv("ComSpec"); shell != "" {
			return shell
		}
		return "cmd.exe"
	}
	if shell := os.Getenv("SHELL"); shell != "" {
		return shell
	}
	return "/bin/sh"
}

type sessionCommand struct {
	fn   func() error
	resp chan error
}

// Session is the Phase 0 single-session worker. The worker owns the PTY
// emulator and publishes copied snapshots; callers never touch a Ghostty
// handle concurrently.
type Session struct {
	pty          *ptyHandle
	cmd          *pty.Cmd
	core         *Core
	output       chan []byte
	commands     chan sessionCommand
	responses    chan []byte
	stop         chan struct{}
	done         chan struct{}
	readDone     chan struct{}
	waitDone     chan struct{}
	responseDone chan struct{}

	mu      sync.RWMutex
	snap    Snapshot
	readErr error
	waitErr error

	closeOnce sync.Once
	stopOnce  sync.Once
}

// StartSession starts one interactive shell. It performs no UI work and does
// not start a timer or polling loop.
func StartSession(ctx context.Context, opts SessionOptions) (*Session, error) {
	opts = opts.withDefaults()
	if opts.Dir != "" {
		if info, err := os.Stat(filepath.Clean(opts.Dir)); err != nil || !info.IsDir() {
			if err == nil {
				err = fmt.Errorf("not a directory")
			}
			return nil, fmt.Errorf("terminal working directory: %w", err)
		}
	}

	rawPTY, err := pty.New()
	if err != nil {
		return nil, fmt.Errorf("create PTY: %w", err)
	}
	p := &ptyHandle{Pty: rawPTY}
	cleanup := func() {
		_ = p.Close()
	}
	if err := p.Resize(int(opts.Cols), int(opts.Rows)); err != nil {
		cleanup()
		return nil, fmt.Errorf("size PTY: %w", err)
	}

	cmd := rawPTY.Command(opts.Shell)
	if runtime.GOOS != "windows" {
		cmd.Args = []string{opts.Shell, "-i"}
	}
	cmd.Dir = opts.Dir
	cmd.Env = append([]string(nil), opts.Env...)
	if err := cmd.Start(); err != nil {
		cleanup()
		return nil, fmt.Errorf("start shell: %w", err)
	}
	stop := make(chan struct{})
	responses := make(chan []byte, 16)

	// The response callback runs synchronously during Core.WriteVT. It only
	// copies into a small session-owned queue; it does not perform a PTY write
	// or call back into the core.
	core, err := NewCore(opts.Cols, opts.Rows, func(data []byte) {
		data = append([]byte(nil), data...)
		select {
		case responses <- data:
		case <-stop:
		}
	})
	if err != nil {
		_ = terminateProcess(cmd)
		_ = p.Close()
		_ = cmd.Wait()
		return nil, err
	}

	s := &Session{
		pty:          p,
		cmd:          cmd,
		core:         core,
		output:       make(chan []byte, 16),
		commands:     make(chan sessionCommand),
		stop:         stop,
		done:         make(chan struct{}),
		readDone:     make(chan struct{}),
		waitDone:     make(chan struct{}),
		responses:    responses,
		responseDone: make(chan struct{}),
	}
	if initial, err := core.Snapshot(); err == nil {
		s.snap = initial
	} else {
		core.Close()
		_ = terminateProcess(cmd)
		_ = p.Close()
		_ = cmd.Wait()
		return nil, fmt.Errorf("initial terminal snapshot: %w", err)
	}

	go s.waitProcess()
	go s.readPTY()
	go s.writeResponses()
	go s.run()
	if ctx != nil {
		go func() {
			select {
			case <-ctx.Done():
				_ = s.Close()
			case <-s.done:
			}
		}()
	}
	return s, nil
}

func (s *Session) writeResponses() {
	defer close(s.responseDone)
	for {
		select {
		case data := <-s.responses:
			if _, err := s.pty.Write(data); err != nil {
				return
			}
		case <-s.stop:
			return
		}
	}
}

func (s *Session) waitProcess() {
	err := s.cmd.Wait()
	s.mu.Lock()
	s.waitErr = err
	s.mu.Unlock()
	close(s.waitDone)
}

func (s *Session) readPTY() {
	defer close(s.readDone)
	buf := make([]byte, 32*1024)
	for {
		n, err := s.pty.Read(buf)
		if n > 0 {
			data := append([]byte(nil), buf[:n]...)
			select {
			case s.output <- data:
			case <-s.stop:
				return
			}
		}
		if err != nil {
			s.mu.Lock()
			s.readErr = err
			s.mu.Unlock()
			return
		}
	}
}

func (s *Session) run() {
	defer close(s.done)
	defer s.core.Close()
	for {
		select {
		case data := <-s.output:
			s.consumeOutput(data)
		case command := <-s.commands:
			err := command.fn()
			command.resp <- err
		case <-s.stop:
			return
		case <-s.readDone:
			s.drainOutput()
			s.stopSession()
			return
		}
	}
}

func (s *Session) consumeOutput(data []byte) {
	s.core.WriteVT(data)
	if snapshot, err := s.core.Snapshot(); err == nil {
		s.mu.Lock()
		s.snap = snapshot
		s.mu.Unlock()
	}
}

func (s *Session) drainOutput() {
	for {
		select {
		case data := <-s.output:
			s.consumeOutput(data)
		default:
			return
		}
	}
}

// Snapshot returns the newest copied screen state. It never exposes a live
// terminal handle.
func (s *Session) Snapshot() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := s.snap
	result.Cells = append([]Cell(nil), s.snap.Cells...)
	return result
}

// WriteInput sends already encoded terminal input to the PTY.
func (s *Session) WriteInput(data []byte) (int, error) {
	select {
	case <-s.stop:
		return 0, errors.New("terminal session is closed")
	default:
	}
	return s.pty.Write(data)
}

// Resize changes PTY and emulator dimensions on the session worker.
func (s *Session) Resize(cols, rows uint16, cellWidth, cellHeight uint32) error {
	if cols == 0 || rows == 0 {
		return fmt.Errorf("terminal dimensions must be positive: %dx%d", cols, rows)
	}
	return s.call(func() error {
		if err := s.pty.Resize(int(cols), int(rows)); err != nil {
			return err
		}
		if err := s.core.Resize(cols, rows, cellWidth, cellHeight); err != nil {
			return err
		}
		snapshot, err := s.core.Snapshot()
		if err == nil {
			s.mu.Lock()
			s.snap = snapshot
			s.mu.Unlock()
		}
		return err
	})
}

func (s *Session) call(fn func() error) error {
	resp := make(chan error, 1)
	command := sessionCommand{fn: fn, resp: resp}
	select {
	case s.commands <- command:
		return <-resp
	case <-s.stop:
		return errors.New("terminal session is closed")
	}
}

// Close stops the process, closes the PTY, waits for the process and worker,
// and leaves no session-owned goroutine behind.
func (s *Session) Close() error {
	s.closeOnce.Do(func() {
		s.stopSession()
		_ = terminateProcess(s.cmd)
		_ = s.pty.Close()
	})
	<-s.waitDone
	<-s.done
	<-s.responseDone
	// Close initiated the process termination, so the PTY's hangup/terminated
	// status is cleanup evidence rather than a failed session result. A later
	// product API can expose s.waitErr separately if it needs exit diagnostics.
	return nil
}

func (s *Session) stopSession() {
	s.stopOnce.Do(func() { close(s.stop) })
}

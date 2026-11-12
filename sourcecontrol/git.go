// Package sourcecontrol provides bounded, local Git operations for Scratchpad.
// It deliberately invokes Git with argument vectors and never through a shell.
package sourcecontrol

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	MaxFiles        = 256
	MaxCommits      = 100
	MaxRefs         = 1000
	MaxPathBytes    = 4096
	MaxMessageBytes = 16 * 1024
	MaxDiffBytes    = 96 * 1024
)

type File struct {
	Path         string `json:"path"`
	OriginalPath string `json:"original_path,omitempty"`
	Status       string `json:"status"`
	Staged       bool   `json:"staged"`
	Unstaged     bool   `json:"unstaged"`
	Untracked    bool   `json:"untracked"`
	Conflict     bool   `json:"conflict"`
}

type Commit struct {
	Hash    string   `json:"hash"`
	Parents []string `json:"parents,omitempty"`
	Author  string   `json:"author"`
	Date    string   `json:"date"`
	Subject string   `json:"subject"`
	Refs    string   `json:"refs,omitempty"`
}

// Ref is a named local branch, remote-tracking branch, or tag. Target is empty
// when the ref does not ultimately name a commit (for example, a blob tag).
type Ref struct {
	FullName string `json:"full_name"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	Target   string `json:"target,omitempty"`
	Head     bool   `json:"head,omitempty"`
}

type ChangedFile struct {
	Path      string `json:"path"`
	Status    string `json:"status"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
}

type CommitDetail struct {
	Hash    string        `json:"hash"`
	Parents []string      `json:"parents,omitempty"`
	Author  string        `json:"author"`
	Email   string        `json:"email,omitempty"`
	Date    string        `json:"date"`
	Subject string        `json:"subject"`
	Body    string        `json:"body,omitempty"`
	Files   []ChangedFile `json:"files"`
}

type Snapshot struct {
	Available bool     `json:"available"`
	Root      string   `json:"root,omitempty"`
	Branch    string   `json:"branch,omitempty"`
	Head      string   `json:"head,omitempty"`
	Upstream  string   `json:"upstream,omitempty"`
	Ahead     int      `json:"ahead,omitempty"`
	Behind    int      `json:"behind,omitempty"`
	Loading   bool     `json:"loading,omitempty"`
	Error     string   `json:"error,omitempty"`
	Files     []File   `json:"files,omitempty"`
	Commits   []Commit `json:"commits,omitempty"`
	Refs      []Ref    `json:"refs,omitempty"`
}

type Diff struct {
	Text      string `json:"text"`
	Truncated bool   `json:"truncated"`
}

var ErrNotRepository = errors.New("workspace is not inside a Git repository")

// Load discovers the containing repository and reads a bounded working-tree
// summary plus recent history. The caller supplies a context so session stop
// and workspace changes can cancel subprocesses.
func Load(ctx context.Context, workspace string) (Snapshot, error) {
	if workspace == "" {
		return Snapshot{}, errors.New("no workspace is open")
	}
	rootBytes, err := run(ctx, workspace, "rev-parse", "--show-toplevel")
	if err != nil {
		if strings.Contains(err.Error(), "not a git repository") {
			return Snapshot{}, ErrNotRepository
		}
		return Snapshot{}, err
	}
	root := filepath.Clean(strings.TrimSpace(string(rootBytes)))
	if root == "." || root == "" {
		return Snapshot{}, errors.New("Git returned an empty repository root")
	}
	statusBytes, err := run(ctx, root, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
	if err != nil {
		return Snapshot{}, err
	}
	snapshot := Snapshot{Available: true, Root: root, Files: []File{}, Commits: []Commit{}, Refs: []Ref{}}
	parseStatus(&snapshot, statusBytes)
	refBytes, err := run(ctx, root, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00%(HEAD)%00%(symref)%00", "refs/heads", "refs/remotes", "refs/tags")
	if err != nil {
		return Snapshot{}, err
	}
	snapshot.Refs = parseRefs(refBytes)
	logBytes, err := run(ctx, root, "log", "--all", "--topo-order", "-n", fmt.Sprint(MaxCommits), "--date=iso-strict", "--format=%H%x00%P%x00%an%x00%ad%x00%s%x00%D%x1e")
	if err == nil {
		snapshot.Commits = parseLog(logBytes)
	} else {
		// A repository with no commits is still a valid source-control workspace.
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) || !bytes.Contains(exitErr.Stderr, []byte("does not have any commits")) {
			return Snapshot{}, err
		}
	}
	return snapshot, nil
}

// LoadHistory returns a bounded ancestry window rooted at a validated commit
// identifier. It is used when a ref points outside the ordinary recent-history
// window, so ref navigation remains useful without loading an unbounded log.
func LoadHistory(ctx context.Context, root, revision string) ([]Commit, error) {
	if root == "" || len(revision) < 7 || len(revision) > 64 || !isHex(revision) {
		return nil, errors.New("repository and valid commit identifier are required")
	}
	output, err := run(ctx, root, "log", "--topo-order", "-n", fmt.Sprint(MaxCommits), "--date=iso-strict",
		"--format=%H%x00%P%x00%an%x00%ad%x00%s%x00%D%x1e", revision, "--")
	if err != nil {
		return nil, err
	}
	return parseLog(output), nil
}

// ReadCommitDetail returns bounded metadata and the first-parent changed-file
// list for one immutable commit snapshot.
func ReadCommitDetail(ctx context.Context, root, revision string) (CommitDetail, error) {
	if root == "" || len(revision) < 7 || len(revision) > 64 || !isHex(revision) {
		return CommitDetail{}, errors.New("repository and valid commit identifier are required")
	}
	metadata, err := run(ctx, root, "show", "-s", "--no-color", "--no-ext-diff", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%b%x00", revision, "--")
	if err != nil {
		return CommitDetail{}, err
	}
	fields := bytes.SplitN(metadata, []byte{0}, 8)
	if len(fields) < 8 {
		return CommitDetail{}, errors.New("Git returned incomplete commit metadata")
	}
	detail := CommitDetail{
		Hash: string(bytes.TrimSpace(fields[0])), Author: string(fields[2]),
		Email: string(fields[3]), Date: string(fields[4]), Subject: strings.TrimSpace(string(fields[5])),
		Body:  strings.TrimSpace(string(fields[6])),
		Files: []ChangedFile{},
	}
	if !isHex(detail.Hash) {
		return CommitDetail{}, errors.New("Git returned an invalid commit identifier")
	}
	for _, parent := range strings.Fields(string(fields[1])) {
		if isHex(parent) {
			detail.Parents = append(detail.Parents, parent)
		}
	}
	statusArgs := []string{"diff-tree", "--no-commit-id", "--name-status", "-r", "-z", "--no-renames"}
	numstatArgs := []string{"diff-tree", "--no-commit-id", "--numstat", "-r", "-z", "--no-renames"}
	if len(detail.Parents) == 0 {
		statusArgs = append(statusArgs, "--root", detail.Hash)
		numstatArgs = append(numstatArgs, "--root", detail.Hash)
	} else {
		statusArgs = append(statusArgs, detail.Parents[0], detail.Hash)
		numstatArgs = append(numstatArgs, detail.Parents[0], detail.Hash)
	}
	statusArgs = append(statusArgs, "--")
	numstatArgs = append(numstatArgs, "--")
	statuses, err := run(ctx, root, statusArgs...)
	if err != nil {
		return CommitDetail{}, err
	}
	// Git's -z name-status format separates status and path into adjacent
	// records. Parse those pairs without treating path bytes as text lines.
	detail.Files = detail.Files[:0]
	statusRecords := bytes.Split(statuses, []byte{0})
	for i := 0; i+1 < len(statusRecords) && len(detail.Files) < MaxFiles; {
		status := statusRecords[i]
		if len(status) == 0 {
			i++
			continue
		}
		path := statusRecords[i+1]
		if len(path) == 0 {
			i++
			continue
		}
		detail.Files = append(detail.Files, ChangedFile{Path: string(path), Status: string(status)})
		i += 2
	}
	numstat, err := run(ctx, root, numstatArgs...)
	if err != nil {
		return CommitDetail{}, err
	}
	for _, record := range bytes.Split(numstat, []byte{0}) {
		firstTab := bytes.IndexByte(record, '\t')
		if firstTab < 0 {
			continue
		}
		rest := record[firstTab+1:]
		secondTab := bytes.IndexByte(rest, '\t')
		if secondTab < 0 {
			continue
		}
		path := string(rest[secondTab+1:])
		for i := range detail.Files {
			if detail.Files[i].Path != path {
				continue
			}
			detail.Files[i].Additions = parseNumstat(record[:firstTab])
			detail.Files[i].Deletions = parseNumstat(rest[:secondTab])
			break
		}
	}
	return detail, nil
}

func parseNumstat(value []byte) int {
	if bytes.Equal(value, []byte("-")) {
		return -1
	}
	parsed, err := strconv.Atoi(string(value))
	if err != nil || parsed < 0 {
		return -1
	}
	return parsed
}

// ReadDiff returns a bounded, read-only diff. kind is "working", "staged", or
// "commit". Historical results never enter Scratchpad's editable document store.
func ReadDiff(ctx context.Context, root, kind, revision, path string, untracked bool) (Diff, error) {
	if root == "" {
		return Diff{}, errors.New("Git repository is unavailable")
	}
	if path != "" {
		if err := validateRelativePath(path); err != nil {
			return Diff{}, err
		}
	}
	var args []string
	switch kind {
	case "working":
		if untracked {
			if path == "" {
				return Diff{}, errors.New("an untracked diff requires a file path")
			}
			args = []string{"diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3", "--", os.DevNull, path}
		} else {
			args = []string{"--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=3"}
		}
	case "staged":
		args = []string{"--literal-pathspecs", "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=3"}
	case "commit":
		if len(revision) < 7 || len(revision) > 64 || !isHex(revision) {
			return Diff{}, errors.New("invalid commit identifier")
		}
		parents, err := run(ctx, root, "rev-list", "--parents", "-n", "1", revision)
		if err != nil {
			return Diff{}, err
		}
		fields := strings.Fields(string(parents))
		if len(fields) > 1 {
			args = []string{"--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=3", fields[1], revision}
		} else {
			args = []string{"--literal-pathspecs", "diff-tree", "--root", "-p", "--no-commit-id", "-r", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=3", revision}
		}
	default:
		return Diff{}, errors.New("unsupported diff kind")
	}
	if path != "" && !untracked {
		args = append(args, "--", path)
	}
	var limited limitedBuffer
	limited.limit = MaxDiffBytes
	if err := runTo(ctx, root, &limited, args...); err != nil {
		var exitErr *exec.ExitError
		// `git diff --no-index` uses exit status 1 to report that the files
		// differ. That is the expected result for an untracked working file.
		if !untracked || kind != "working" || !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 {
			return Diff{}, err
		}
	}
	text := limited.buf.String()
	if limited.truncated {
		text += "\n\n[Diff truncated at 96 KiB]\n"
	}
	return Diff{Text: text, Truncated: limited.truncated}, nil
}

// Mutate performs one local index/commit operation. It does not fetch, push, or
// otherwise access a remote. The caller serializes these operations per runtime.
func Mutate(ctx context.Context, root, operation, path, originalPath, message string) error {
	if root == "" {
		return errors.New("Git repository is unavailable")
	}
	switch operation {
	case "stage", "unstage":
		if err := validateRelativePath(path); err != nil {
			return err
		}
		if originalPath != "" {
			if err := validateRelativePath(originalPath); err != nil {
				return err
			}
		}
		paths := []string{path}
		if originalPath != "" && originalPath != path {
			paths = append(paths, originalPath)
		}
		if operation == "stage" {
			args := append([]string{"--literal-pathspecs", "add", "-A", "--"}, paths...)
			_, err := run(ctx, root, args...)
			return err
		}
		args := append([]string{"--literal-pathspecs", "restore", "--staged", "--"}, paths...)
		_, err := run(ctx, root, args...)
		return err
	case "commit":
		if strings.TrimSpace(message) == "" || len(message) > MaxMessageBytes || strings.ContainsRune(message, 0) {
			return errors.New("commit message must contain 1 to 16384 non-NUL bytes")
		}
		commitCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(commitCtx, "git", "--no-pager", "--no-optional-locks", "-C", root, "commit", "--file=-")
		cmd.Stdin = strings.NewReader(message)
		var output limitedBuffer
		output.limit = 32 * 1024
		cmd.Stdout, cmd.Stderr = &output, &output
		if err := cmd.Run(); err != nil {
			if errors.Is(commitCtx.Err(), context.DeadlineExceeded) {
				return errors.New("Git commit timed out after 2 minutes")
			}
			return fmt.Errorf("git commit: %s", strings.TrimSpace(output.buf.String()))
		}
		return nil
	default:
		return errors.New("unsupported Git operation")
	}
}

func run(ctx context.Context, root string, args ...string) ([]byte, error) {
	var output limitedBuffer
	output.limit = 256 * 1024
	if err := runTo(ctx, root, &output, args...); err != nil {
		return nil, err
	}
	if output.truncated {
		return nil, errors.New("Git output exceeded the operation limit")
	}
	return output.buf.Bytes(), nil
}

func runTo(ctx context.Context, root string, output *limitedBuffer, args ...string) error {
	bounded, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	fullArgs := []string{"--no-pager", "--no-optional-locks", "-C", root}
	fullArgs = append(fullArgs, args...)
	cmd := exec.CommandContext(bounded, "git", fullArgs...)
	cmd.Stdout = output
	var stderr limitedBuffer
	stderr.limit = 8 * 1024
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(bounded.Err(), context.DeadlineExceeded) {
			return errors.New("Git operation timed out")
		}
		message := strings.TrimSpace(stderr.buf.String())
		if message == "" {
			message = err.Error()
		}
		return fmt.Errorf("git %s: %s: %w", strings.Join(args, " "), message, err)
	}
	return nil
}

func parseStatus(snapshot *Snapshot, data []byte) {
	records := bytes.Split(data, []byte{0})
	for index := 0; index < len(records); index++ {
		record := records[index]
		if len(record) == 0 {
			continue
		}
		if bytes.HasPrefix(record, []byte("# ")) {
			key, value, found := strings.Cut(string(record[2:]), " ")
			if !found {
				continue
			}
			switch key {
			case "branch.head":
				if value != "(detached)" {
					snapshot.Branch = value
				}
			case "branch.oid":
				snapshot.Head = value
			case "branch.upstream":
				snapshot.Upstream = value
			case "branch.ab":
				fields := strings.Fields(value)
				if len(fields) == 2 && strings.HasPrefix(fields[0], "+") && strings.HasPrefix(fields[1], "-") {
					snapshot.Ahead, _ = strconv.Atoi(strings.TrimPrefix(fields[0], "+"))
					snapshot.Behind, _ = strconv.Atoi(strings.TrimPrefix(fields[1], "-"))
				}
			}
			continue
		}
		if len(snapshot.Files) >= MaxFiles {
			continue
		}
		recordKind := record[0]
		if recordKind == '?' {
			if len(record) < 3 || record[1] != ' ' {
				continue
			}
			file := File{Path: string(record[2:]), Status: "??", Untracked: true, Unstaged: true}
			snapshot.Files = append(snapshot.Files, file)
			continue
		}
		prefixFields := 0
		switch recordKind {
		case '1':
			prefixFields = 8
		case '2':
			prefixFields = 9
		case 'u':
			prefixFields = 10
		default:
			continue
		}
		pathStart := -1
		spaces := 0
		for i, b := range record {
			if b == ' ' {
				spaces++
				if spaces == prefixFields {
					pathStart = i + 1
					break
				}
			}
		}
		if pathStart < 5 || pathStart >= len(record) {
			continue
		}
		x, y := record[2], record[3]
		path := string(record[pathStart:])
		file := File{Path: path, Status: string([]byte{x, y})}
		file.Conflict = recordKind == 'u' || file.Status == "DD" || file.Status == "AU" || file.Status == "UD" ||
			file.Status == "UA" || file.Status == "DU" || file.Status == "AA" || file.Status == "UU"
		file.Staged = x != '.'
		file.Unstaged = y != '.'
		snapshot.Files = append(snapshot.Files, file)
		// Porcelain v2 -z emits the original path as the next record for a rename.
		if recordKind == '2' {
			if index+1 < len(records) {
				snapshot.Files[len(snapshot.Files)-1].OriginalPath = string(records[index+1])
				index++
			}
		}
	}
}

func parseRefs(data []byte) []Ref {
	refs := make([]Ref, 0, min(bytes.Count(data, []byte{0})/7, MaxRefs))
	position := 0
	for position < len(data) && len(refs) < MaxRefs {
		fields := [7][]byte{}
		complete := true
		for i := range fields {
			end := bytes.IndexByte(data[position:], 0)
			if end < 0 {
				complete = false
				break
			}
			end += position
			fields[i] = data[position:end]
			position = end + 1
		}
		if !complete {
			break
		}
		for position < len(data) && (data[position] == '\n' || data[position] == '\r') {
			position++
		}
		fullName := string(fields[0])
		kind, name := "", ""
		switch {
		case strings.HasPrefix(fullName, "refs/heads/"):
			kind, name = "branch", strings.TrimPrefix(fullName, "refs/heads/")
		case strings.HasPrefix(fullName, "refs/remotes/"):
			kind, name = "remote", strings.TrimPrefix(fullName, "refs/remotes/")
		case strings.HasPrefix(fullName, "refs/tags/"):
			kind, name = "tag", strings.TrimPrefix(fullName, "refs/tags/")
		default:
			continue
		}
		if name == "" || len(fields[6]) != 0 || !isHex(string(fields[1])) {
			continue
		}
		target := ""
		if string(fields[2]) == "commit" {
			target = string(fields[1])
		} else if kind == "tag" && string(fields[4]) == "commit" && isHex(string(fields[3])) {
			target = string(fields[3])
		}
		refs = append(refs, Ref{
			FullName: fullName, Name: name, Kind: kind, Target: target,
			Head: bytes.Equal(fields[5], []byte("*")),
		})
	}
	return refs
}

func parseLog(data []byte) []Commit {
	sections := bytes.Split(data, []byte{0x1e})
	commits := make([]Commit, 0, min(len(sections), MaxCommits))
	for _, section := range sections {
		if len(commits) >= MaxCommits {
			break
		}
		fields := bytes.Split(section, []byte{0})
		if len(fields) < 6 || len(fields[0]) != 40 && len(fields[0]) != 64 {
			continue
		}
		hash := string(bytes.TrimSpace(fields[0]))
		if !isHex(hash) {
			continue
		}
		commit := Commit{Hash: hash, Author: string(fields[2]), Date: string(fields[3]), Subject: string(fields[4]), Refs: strings.TrimSpace(string(fields[5]))}
		for _, parent := range strings.Fields(string(fields[1])) {
			if isHex(parent) {
				commit.Parents = append(commit.Parents, parent)
			}
		}
		commits = append(commits, commit)
	}
	return commits
}

func validateRelativePath(path string) error {
	if path == "" || len(path) > MaxPathBytes || strings.ContainsRune(path, 0) || filepath.IsAbs(path) {
		return errors.New("Git path must be a bounded relative repository path")
	}
	clean := filepath.Clean(path)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return errors.New("Git path escapes the repository")
	}
	return nil
}

// ValidateRelativePath rejects empty, absolute, and repository-escaping paths
// using the current platform's path rules. Git paths may contain a backslash
// on POSIX systems, where it is an ordinary filename character.
func ValidateRelativePath(path string) error {
	return validateRelativePath(path)
}

func isHex(value string) bool {
	if value == "" {
		return false
	}
	for _, char := range value {
		if !('0' <= char && char <= '9') && !('a' <= char && char <= 'f') && !('A' <= char && char <= 'F') {
			return false
		}
	}
	return true
}

type limitedBuffer struct {
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (b *limitedBuffer) Write(data []byte) (int, error) {
	remaining := b.limit - b.buf.Len()
	if remaining <= 0 {
		b.truncated = true
		return len(data), nil
	}
	if len(data) > remaining {
		_, _ = b.buf.Write(data[:remaining])
		b.truncated = true
		return len(data), nil
	}
	return b.buf.Write(data)
}

package workspace

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// FileID is a platform file identity when the host exposes one. A and B are
// intentionally opaque to callers; they are only compared for equality.
type FileID struct {
	A     uint64
	B     uint64
	Valid bool
}

// DiskVersion separates cheap metadata observations from a verified content
// identity. Hash is meaningful only when Verified is true.
type DiskVersion struct {
	Exists    bool
	Size      int64
	ModTime   time.Time
	FileID    FileID
	LinkCount uint64
	Hash      [32]byte
	Verified  bool
}

// Equal reports whether two observations identify the same file bytes. A
// verified content hash is authoritative; unverified observations fall back
// to the available metadata.
func (v DiskVersion) Equal(other DiskVersion) bool {
	if v.Exists != other.Exists {
		return false
	}
	if !v.Exists {
		return true
	}
	if v.Verified && other.Verified {
		return v.Hash == other.Hash
	}
	return v.Size == other.Size && v.ModTime.Equal(other.ModTime) && v.FileID == other.FileID
}

// EqualForReplacement reports whether two versions identify the same bytes
// and, when both identities are available, the same underlying file. The
// stronger identity check is reserved for conditional replacements so the
// general content-oriented Equal semantics remain unchanged.
func (v DiskVersion) EqualForReplacement(other DiskVersion) bool {
	if !v.Equal(other) {
		return false
	}
	return !v.Exists || !v.FileID.Valid || !other.FileID.Valid || v.FileID == other.FileID
}

type FileSnapshot struct {
	Path      string
	Data      []byte
	Mode      fs.FileMode
	Version   DiskVersion
	IsSymlink bool
}

// FileStore is the filesystem seam used by document lifecycle code. The OS
// implementation is deliberately small; tests can provide an adapter without
// making Document depend on the OS.
//
// Save returns the verified post-write identity on success. When the
// replacement completes but the parent directory cannot be flushed, Save
// returns the verified version together with an error wrapping
// ErrParentDirSync so callers can adopt the new identity while still
// surfacing the weakened durability.
type FileStore interface {
	Load(path string) (FileSnapshot, error)
	Observe(path string) (DiskVersion, error)
	Verify(path string) (DiskVersion, error)
	Save(path string, data []byte, mode fs.FileMode) (DiskVersion, error)
}

// ConditionalFileStore can replace a file only when it still has the
// supplied verified version. It is optional so lightweight test and recovery
// stores can continue to implement FileStore without an OS-level replace
// primitive.
type ConditionalFileStore interface {
	SaveIfVersion(path string, data []byte, mode fs.FileMode, expected DiskVersion) (DiskVersion, error)
}

type OSFileStore struct{}

// ErrUnsupportedTextFile is returned when a file is too large or appears to
// contain binary data that the text editor cannot safely present.
var ErrUnsupportedTextFile = errors.New("unsupported text file")

const (
	maxTextFileBytes = int64(64 << 20)
	textProbeBytes   = 8 << 10
)

type UnsupportedTextFileError struct {
	Path   string
	Reason string
}

func (e *UnsupportedTextFileError) Error() string {
	if e == nil {
		return ErrUnsupportedTextFile.Error()
	}
	return fmt.Sprintf("%s cannot be opened in the text editor: %s", e.Path, e.Reason)
}

func (e *UnsupportedTextFileError) Unwrap() error { return ErrUnsupportedTextFile }

func NewOSFileStore() OSFileStore { return OSFileStore{} }

func (OSFileStore) Load(path string) (FileSnapshot, error) {
	clean := filepath.Clean(path)
	lstat, err := os.Lstat(clean)
	if err != nil {
		return FileSnapshot{}, err
	}
	if !lstat.Mode().IsRegular() && lstat.Mode()&os.ModeSymlink == 0 {
		return FileSnapshot{}, errors.New("path is not a regular file")
	}
	file, err := os.Open(clean)
	if err != nil {
		return FileSnapshot{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return FileSnapshot{}, err
	}
	if !info.Mode().IsRegular() {
		return FileSnapshot{}, errors.New("path is not a regular file")
	}
	if info.Size() > maxTextFileBytes {
		return FileSnapshot{}, &UnsupportedTextFileError{Path: clean, Reason: "file exceeds the 64 MiB text-editor limit"}
	}
	probeLength := min(info.Size(), int64(textProbeBytes))
	probe := make([]byte, int(probeLength))
	if probeLength > 0 {
		if _, err := io.ReadFull(file, probe); err != nil {
			return FileSnapshot{}, err
		}
	}
	if reason := binaryTextProbeReason(probe); reason != "" {
		return FileSnapshot{}, &UnsupportedTextFileError{Path: clean, Reason: reason}
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return FileSnapshot{}, err
	}
	data, err := io.ReadAll(io.LimitReader(file, maxTextFileBytes+1))
	if err != nil {
		return FileSnapshot{}, err
	}
	if int64(len(data)) > maxTextFileBytes {
		return FileSnapshot{}, &UnsupportedTextFileError{Path: clean, Reason: "file exceeds the 64 MiB text-editor limit"}
	}
	if reason := binaryTextProbeReason(data[:min(len(data), textProbeBytes)]); reason != "" {
		return FileSnapshot{}, &UnsupportedTextFileError{Path: clean, Reason: reason}
	}
	version, err := verifiedVersion(clean, data)
	if err != nil {
		return FileSnapshot{}, err
	}
	info, err = os.Stat(clean)
	if err != nil {
		return FileSnapshot{}, err
	}
	return FileSnapshot{Path: clean, Data: data, Mode: info.Mode(), Version: version, IsSymlink: lstat.Mode()&os.ModeSymlink != 0}, nil
}

func binaryTextProbeReason(sample []byte) string {
	if len(sample) == 0 {
		return ""
	}
	if bytes.HasPrefix(sample, []byte("Bud1")) {
		return "file signature identifies binary macOS metadata"
	}
	if bytes.HasPrefix(sample, []byte("P6\n")) || bytes.HasPrefix(sample, []byte("P6\r\n")) ||
		bytes.HasPrefix(sample, []byte("P6 ")) || bytes.HasPrefix(sample, []byte("P6\t")) {
		return "file signature identifies a binary PPM image"
	}
	for _, signature := range [][]byte{
		{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a},
		{0xff, 0xd8, 0xff},
		{'G', 'I', 'F', '8', '7', 'a'},
		{'G', 'I', 'F', '8', '9', 'a'},
		{'B', 'M'},
		{'P', 'K', 0x03, 0x04},
		{0x7f, 'E', 'L', 'F'},
	} {
		if bytes.HasPrefix(sample, signature) {
			return "file signature identifies a binary format"
		}
	}
	if bytes.IndexByte(sample, 0) >= 0 {
		return "file contains NUL bytes"
	}
	controls := 0
	for _, value := range sample {
		if value < 0x20 && value != '\t' && value != '\n' && value != '\r' && value != '\f' {
			controls++
		} else if value == 0x7f {
			controls++
		}
	}
	if controls > len(sample)/100 {
		return "file contains binary control data"
	}
	return ""
}

func (s OSFileStore) Observe(path string) (DiskVersion, error) {
	info, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return DiskVersion{}, nil
		}
		return DiskVersion{}, err
	}
	if !info.Mode().IsRegular() {
		return DiskVersion{}, errors.New("path is not a regular file")
	}
	return observedVersion(path, info), nil
}

func (s OSFileStore) Verify(path string) (DiskVersion, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return DiskVersion{}, nil
		}
		return DiskVersion{}, err
	}
	return verifiedVersion(path, data)
}

func (s OSFileStore) Save(path string, data []byte, mode fs.FileMode) (DiskVersion, error) {
	if err := AtomicWriteFile(path, data, mode); err != nil {
		if errors.Is(err, ErrParentDirSync) {
			version, verr := s.Verify(path)
			if verr == nil && version.Verified && version.Hash == sha256.Sum256(data) {
				return version, err
			}
		}
		return DiskVersion{}, err
	}
	return s.Verify(path)
}

func (s OSFileStore) SaveIfVersion(path string, data []byte, mode fs.FileMode, expected DiskVersion) (DiskVersion, error) {
	if err := AtomicWriteFileIfVersion(path, data, mode, expected); err != nil {
		if errors.Is(err, ErrParentDirSync) {
			version, verr := s.Verify(path)
			if verr == nil && version.Verified && version.Hash == sha256.Sum256(data) {
				return version, err
			}
		}
		return DiskVersion{}, err
	}
	return s.Verify(path)
}

func observedVersion(path string, info fs.FileInfo) DiskVersion {
	return DiskVersion{
		Exists:    true,
		Size:      info.Size(),
		ModTime:   info.ModTime(),
		FileID:    fileID(path, info),
		LinkCount: linkCount(path, info),
	}
}

func verifiedVersion(path string, data []byte) (DiskVersion, error) {
	info, err := os.Stat(path)
	if err != nil {
		return DiskVersion{}, err
	}
	version := observedVersion(path, info)
	version.Hash = sha256.Sum256(data)
	version.Verified = true
	return version, nil
}

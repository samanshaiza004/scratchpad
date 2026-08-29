package workspace

import (
	"crypto/sha256"
	"errors"
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
type FileStore interface {
	Load(path string) (FileSnapshot, error)
	Observe(path string) (DiskVersion, error)
	Verify(path string) (DiskVersion, error)
	Save(path string, data []byte, mode fs.FileMode) (DiskVersion, error)
}

type OSFileStore struct{}

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
	data, err := os.ReadFile(clean)
	if err != nil {
		return FileSnapshot{}, err
	}
	version, err := verifiedVersion(clean, data)
	if err != nil {
		return FileSnapshot{}, err
	}
	info, err := os.Stat(clean)
	if err != nil {
		return FileSnapshot{}, err
	}
	return FileSnapshot{Path: clean, Data: data, Mode: info.Mode(), Version: version, IsSymlink: lstat.Mode()&os.ModeSymlink != 0}, nil
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

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

type boundedHeaderReader struct{ read int }

func (r *boundedHeaderReader) Read(p []byte) (int, error) {
	r.read += len(p)
	for i := range p {
		p[i] = 0x7f
	}
	return len(p), nil
}
func TestUnsupportedImageOnlyReadsHeader(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.bin")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := file.Truncate(100 << 20); err != nil {
		t.Fatal(err)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	reader := &boundedHeaderReader{}
	snapshot, err := inspectImageHeader(reader, path, info)
	if err != nil || snapshot.Format != "" || snapshot.Error == "" || len(snapshot.Data) != 0 || reader.read != 33 {
		t.Fatalf("unsupported read: snapshot=%+v reads=%d err=%v", snapshot, reader.read, err)
	}
	snapshot, err = (OSFileStore{}).LoadImage(path)
	if err != nil || snapshot.Format != "" || snapshot.Error == "" || len(snapshot.Data) != 0 || snapshot.Version.Verified {
		t.Fatalf("large unsupported LoadImage should neither load nor hash contents: %+v %v", snapshot, err)
	}
}
func TestImageMetadataDoesNotRetainEncodedBytes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pixel.qoi")
	encoded := []byte{'q', 'o', 'i', 'f', 0, 0, 0, 1, 0, 0, 0, 1, 4, 0, 0xff, 128, 96, 180, 255, 0, 0, 0, 0, 0, 0, 0, 1}
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		t.Fatal(err)
	}
	store := OSFileStore{}
	metadata, err := store.InspectImage(path)
	if err != nil || metadata.Format != "QOI" || metadata.Width != 1 || metadata.Height != 1 || len(metadata.Data) != 0 || metadata.Version.Verified {
		t.Fatalf("metadata=%+v err=%v", metadata, err)
	}
	loaded, err := store.LoadImage(path)
	if err != nil || !bytes.Equal(loaded.Data, encoded) || !loaded.Version.Verified {
		t.Fatalf("loaded=%+v err=%v", loaded, err)
	}
}

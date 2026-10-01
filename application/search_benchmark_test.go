package application

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func BenchmarkFindCurrentLimited10MiB(b *testing.B) {
	const size = 10 << 20
	for _, tc := range []struct {
		name  string
		query []byte
	}{
		{name: "late-match", query: []byte("needle")},
		{name: "no-match", query: []byte("not-present")},
	} {
		b.Run(tc.name, func(b *testing.B) {
			dir := b.TempDir()
			path := filepath.Join(dir, "large.txt")
			source := bytes.Repeat([]byte{'x'}, size)
			if tc.name == "late-match" {
				copy(source[len(source)-len(tc.query):], tc.query)
			}
			if err := os.WriteFile(path, source, 0o644); err != nil {
				b.Fatal(err)
			}
			app := New(nil)
			if err := app.OpenPath(path); err != nil {
				b.Fatal(err)
			}
			b.SetBytes(size)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_ = app.FindCurrentLimited(app.Active, tc.query, 1000)
			}
		})
	}
}

package document

import (
	"bytes"
	"testing"
)

func BenchmarkBuildLineIndex(b *testing.B) {
	for _, size := range []int{100 << 10, 1 << 20, 10 << 20} {
		source := bytes.Repeat([]byte("package main { return 1 }\n"), size/25+1)
		source = source[:size]
		b.Run(sizeName(size), func(b *testing.B) {
			b.SetBytes(int64(len(source)))
			for i := 0; i < b.N; i++ {
				_ = BuildLineIndex(source)
			}
		})
	}
}

func sizeName(size int) string {
	switch size {
	case 100 << 10:
		return "100KiB"
	case 1 << 20:
		return "1MiB"
	case 10 << 20:
		return "10MiB"
	default:
		return "custom"
	}
}

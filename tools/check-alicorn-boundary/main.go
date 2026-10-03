package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var runtimeFieldAccess = regexp.MustCompile(`\b(?:rt|runtime)\.[A-Za-z_][A-Za-z0-9_]*\b`)

func main() {
	root := filepath.Join("frontends", "alicorn")
	var violations []string
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || filepath.Ext(path) != ".odin" || strings.HasSuffix(path, "_test.odin") {
			return nil
		}
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
		lineNumber := 0
		for scanner.Scan() {
			lineNumber++
			if runtimeFieldAccess.Match(scanner.Bytes()) {
				violations = append(violations, fmt.Sprintf("%s:%d: use Alicorn's public runtime query API instead of direct Runtime fields", path, lineNumber))
			}
		}
		scanErr := scanner.Err()
		closeErr := file.Close()
		if scanErr != nil {
			return scanErr
		}
		return closeErr
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if len(violations) > 0 {
		for _, violation := range violations {
			fmt.Fprintln(os.Stderr, violation)
		}
		os.Exit(1)
	}
	fmt.Println("Scratchpad Alicorn frontend does not access Runtime implementation fields directly.")
}

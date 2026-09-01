package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"scratchpad/language/treesitter"
)

func main() {
	backend := flag.String("backend", "pure", "parser backend: pure or official")
	sizes := flag.String("sizes", "102400,1048576,10485760", "comma-separated source sizes in bytes")
	flag.Parse()
	for _, raw := range strings.Split(*sizes, ",") {
		size, err := strconv.Atoi(strings.TrimSpace(raw))
		if err != nil {
			fatal(err)
		}
		result, err := treesitter.Run(treesitter.BenchmarkConfig{Backend: *backend, Size: size})
		if err != nil {
			fatal(err)
		}
		data, err := treesitter.MarshalResult(result)
		if err != nil {
			fatal(err)
		}
		fmt.Println(string(data))
	}
}

func fatal(err error) {
	_, _ = fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

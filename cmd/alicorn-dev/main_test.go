package main

import (
	"strings"
	"testing"
)

func TestValidateDarwinBackendArtifact(t *testing.T) {
	loadCommands := `Load command 12
          cmd LC_RPATH
      cmdsize 32
         path @loader_path (offset 12)
Load command 13
          cmd LC_RPATH
      cmdsize 40
         path @executable_path (offset 12)
`
	linkedLibraries := `out/libscratchpad_backend.dylib:
	libscratchpad_backend.dylib (compatibility version 0.0.0, current version 0.0.0)
	@rpath/libcaliber_ffi.dylib (compatibility version 0.0.0, current version 0.0.0)
`

	if err := validateDarwinBackendArtifact(loadCommands, linkedLibraries); err != nil {
		t.Fatalf("valid relocatable backend rejected: %v", err)
	}
}

func TestValidateDarwinBackendArtifactRejectsInvalidLoadCommands(t *testing.T) {
	validLoadCommands := `Load command 12
          cmd LC_RPATH
      cmdsize 32
         path @loader_path (offset 12)
Load command 13
          cmd LC_RPATH
      cmdsize 40
         path @executable_path (offset 12)
`
	validLinkedLibraries := "\t@rpath/libcaliber_ffi.dylib (compatibility version 0.0.0, current version 0.0.0)\n"
	tests := []struct {
		name            string
		loadCommands    string
		linkedLibraries string
		wantError       string
	}{
		{
			name: "duplicate loader rpath",
			loadCommands: validLoadCommands + `Load command 14
          cmd LC_RPATH
      cmdsize 32
         path @loader_path (offset 12)
`,
			linkedLibraries: validLinkedLibraries,
			wantError:       "@loader_path",
		},
		{
			name:            "missing executable rpath",
			loadCommands:    strings.Replace(validLoadCommands, "Load command 13\n          cmd LC_RPATH\n      cmdsize 40\n         path @executable_path (offset 12)\n", "", 1),
			linkedLibraries: validLinkedLibraries,
			wantError:       "@executable_path",
		},
		{
			name:            "unrelocated Caliber dependency",
			loadCommands:    validLoadCommands,
			linkedLibraries: "\t/old/build/path/libcaliber_ffi.dylib (compatibility version 0.0.0, current version 0.0.0)\n",
			wantError:       "@rpath/libcaliber_ffi.dylib",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateDarwinBackendArtifact(test.loadCommands, test.linkedLibraries)
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("validation error = %v, want error containing %q", err, test.wantError)
			}
		})
	}
}

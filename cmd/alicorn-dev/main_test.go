package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestAccessKitLinkerFlagsForWindows(t *testing.T) {
	root := filepath.Join("workspace", "alicorn")
	flags, library, err := accessKitLinkerFlagsFor(root, "windows", "amd64")
	if err != nil {
		t.Fatal(err)
	}
	libraryDirectory := filepath.Join(root, ".deps", "accesskit", "accesskit-c-0.23.1", "lib", "windows", "x86_64", "msvc", "static")
	if !strings.Contains(flags, "/LIBPATH:"+quoteLinkerPath(libraryDirectory)) {
		t.Fatalf("linker flags %q do not point at selected Alicorn dependency directory %q", flags, libraryDirectory)
	}
	for _, libraryName := range []string{"bcrypt.lib", "ntdll.lib", "propsys.lib", "runtimeobject.lib", "uiautomationcore.lib", "userenv.lib", "ws2_32.lib"} {
		if !strings.Contains(flags, libraryName) {
			t.Errorf("linker flags %q omit %s", flags, libraryName)
		}
	}
	if want := filepath.Join(libraryDirectory, "accesskit.lib"); library != want {
		t.Fatalf("AccessKit library = %q, want %q", library, want)
	}
}

func TestAccessKitLinkerFlagsForMacOS(t *testing.T) {
	for _, test := range []struct {
		goarch string
		arch   string
	}{
		{goarch: "arm64", arch: "arm64"},
		{goarch: "amd64", arch: "x86_64"},
	} {
		flags, library, err := accessKitLinkerFlagsFor("/workspace/alicorn", "darwin", test.goarch)
		if err != nil {
			t.Fatal(err)
		}
		libraryDirectory := filepath.Join("/workspace/alicorn", ".deps", "accesskit", "accesskit-c-0.23.1", "lib", "macos", test.arch, "static")
		if !strings.Contains(flags, "-L"+quoteLinkerPath(libraryDirectory)) {
			t.Errorf("linker flags %q do not point at %q", flags, libraryDirectory)
		}
		if want := filepath.Join(libraryDirectory, "libaccesskit.a"); library != want {
			t.Errorf("AccessKit library = %q, want %q", library, want)
		}
		for _, linkerToken := range []string{"-framework AppKit", "-framework Foundation", "-framework CoreFoundation", "-lobjc", "-lc++"} {
			if !strings.Contains(flags, linkerToken) {
				t.Errorf("linker flags %q omit %s", flags, linkerToken)
			}
		}
	}
}

func TestAccessKitLinkerFlagsForLinux(t *testing.T) {
	flags, library, err := accessKitLinkerFlagsFor("/workspace/alicorn", "linux", "amd64")
	if err != nil || flags != "" || library != "" {
		t.Fatalf("Linux AccessKit linker contract = (%q, %q, %v), want empty flags and library", flags, library, err)
	}
}

func TestAppendLinkerFlags(t *testing.T) {
	args := []string{"build", "frontends/alicorn"}
	if got := appendLinkerFlags(args, ""); len(got) != len(args) {
		t.Fatalf("empty linker flags added an argument: %v", got)
	}
	got := appendLinkerFlags(args, "/LIBPATH:C:/deps/accesskit accesskit.lib")
	if len(got) != len(args)+1 || got[len(got)-1] != "-extra-linker-flags:/LIBPATH:C:/deps/accesskit accesskit.lib" {
		t.Fatalf("linker flags were not passed as one Odin argument: %v", got)
	}
}

func TestValidateLockedRevision(t *testing.T) {
	tests := []struct {
		name    string
		actual  string
		allow   bool
		wantErr bool
	}{
		{name: "locked revision", actual: "abc", wantErr: false},
		{name: "candidate without override", actual: "def", wantErr: true},
		{name: "candidate with override", actual: "def", allow: true, wantErr: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateLockedRevision("Caliber", test.actual, "abc", test.allow)
			if (err != nil) != test.wantErr {
				t.Fatalf("validateLockedRevision() error = %v, wantErr %t", err, test.wantErr)
			}
		})
	}
}

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

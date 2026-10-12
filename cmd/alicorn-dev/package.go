package main

import (
	"archive/zip"
	"crypto/sha256"
	"debug/pe"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"
)

const (
	packageOutputMarker = "scratchpad-consumer-package-v1\n"
	macSDLVersion       = "3.4.16"
	macSDLSource        = "https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/SDL3-3.4.16.tar.gz"
	macSDLSourceSHA256  = "7322236cd12090c3eb40b9728be4d49c76f66ad17d04369584d4ecad5cf77c68"
)

type packageMetadata struct {
	Name                string   `json:"name"`
	Version             string   `json:"version"`
	BundleIdentifier    string   `json:"bundleIdentifier"`
	ExecutableName      string   `json:"executableName"`
	MinimumMacOSVersion string   `json:"minimumMacOSVersion"`
	Icon                string   `json:"icon"`
	Resources           []string `json:"resources"`
	PrivateLibraries    []string `json:"privateLibraries"`
}

type goModuleLicense struct {
	Path     string   `json:"path"`
	Version  string   `json:"version"`
	Licenses []string `json:"licenses"`
}

type scratchpadBuildManifest struct {
	Schema       uint32            `json:"schema"`
	Application  releaseApp        `json:"application"`
	Source       releaseSource     `json:"source"`
	Target       releaseTarget     `json:"target"`
	Dependencies releaseDeps       `json:"dependencies"`
	Licenses     []string          `json:"licenses"`
	Validation   releaseValidation `json:"validation"`
}

type releaseApp struct {
	Name       string `json:"name"`
	Version    string `json:"version"`
	Executable string `json:"executable"`
}

type releaseSource struct {
	Scratchpad string `json:"scratchpadRevision"`
	Alicorn    string `json:"alicornRevision"`
	Caliber    string `json:"caliberRevision"`
}

type releaseTarget struct {
	OS             string `json:"os"`
	Architecture   string `json:"architecture"`
	WindowsGUI     bool   `json:"windowsGuiSubsystem"`
	MacAdHocSigned bool   `json:"macAdHocSigned"`
	Notarized      bool   `json:"notarized"`
}

type releaseDeps struct {
	GoModules []goModuleLicense `json:"goModules"`
	SDL3      releaseSDL        `json:"sdl3"`
}

type releaseSDL struct {
	Version string `json:"version"`
	Linkage string `json:"linkage"`
}

type releaseValidation struct {
	NativeDependencyAudit     string `json:"nativeDependencyAudit"`
	CodeSignatureVerification string `json:"codeSignatureVerification,omitempty"`
	RelocatedArchiveLaunch    string `json:"relocatedArchiveLaunch"`
}

type releaseArtifact struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"sizeBytes"`
}

type releaseManifest struct {
	Schema       uint32            `json:"schema"`
	Application  releaseApp        `json:"application"`
	Source       releaseSource     `json:"source"`
	Target       releaseTarget     `json:"target"`
	Dependencies releaseDeps       `json:"dependencies"`
	Licenses     []string          `json:"licenses"`
	Validation   releaseValidation `json:"validation"`
	Artifacts    []releaseArtifact `json:"artifacts"`
}

type licenseSource struct {
	name string
	path string
}

type moduleRecord struct {
	path    string
	version string
	dir     string
}

func packageScratchpad(root, alicornRoot, caliberRoot, goExe, odinExe, output, version string) error {
	if runtime.GOOS != "windows" && runtime.GOOS != "darwin" {
		return fmt.Errorf("consumer packages are supported only on Windows and macOS, not %s", runtime.GOOS)
	}
	if runtime.GOOS == "windows" && runtime.GOARCH != "amd64" {
		return fmt.Errorf("Scratchpad Windows packages require amd64, got %s", runtime.GOARCH)
	}
	if runtime.GOOS == "darwin" && runtime.GOARCH != "arm64" {
		return fmt.Errorf("Scratchpad macOS packages require arm64, got %s", runtime.GOARCH)
	}
	if runtime.GOOS == "darwin" {
		previous, wasSet := os.LookupEnv("MACOSX_DEPLOYMENT_TARGET")
		if err := os.Setenv("MACOSX_DEPLOYMENT_TARGET", "13.0"); err != nil {
			return fmt.Errorf("set macOS deployment target: %w", err)
		}
		defer func() {
			if wasSet {
				_ = os.Setenv("MACOSX_DEPLOYMENT_TARGET", previous)
			} else {
				_ = os.Unsetenv("MACOSX_DEPLOYMENT_TARGET")
			}
		}()
	}
	version = strings.TrimPrefix(version, "v")
	if !validPackageVersion(version) {
		return fmt.Errorf("invalid package version %q; use major.minor.patch such as 0.1.1", version)
	}
	output, err := safePackageOutput(root, output)
	if err != nil {
		return err
	}
	parent := filepath.Dir(output)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return err
	}
	if err := validateReplaceablePackageOutput(output); err != nil {
		return err
	}
	staging, err := os.MkdirTemp(parent, ".scratchpad-package-staging-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(staging)

	buildDir := filepath.Join(staging, "build")
	appDir := filepath.Join(staging, "app")
	if err := os.MkdirAll(buildDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		return err
	}
	var macSDLRuntime, macSDLLicense string
	if runtime.GOOS == "darwin" {
		macSDLRuntime, macSDLLicense, err = buildPinnedMacSDL(root, buildDir)
		if err != nil {
			return fmt.Errorf("build pinned SDL runtime: %w", err)
		}
	}

	buildEnv, caliberLibrary, err := buildCaliberAndBackend(root, caliberRoot, goExe, buildDir, true)
	if err != nil {
		return fmt.Errorf("build optimized Caliber and Scratchpad backend: %w", err)
	}
	if err := stageCaliberLibrary(caliberLibrary, buildDir); err != nil {
		return err
	}
	collectionArg := "-collection:alicorn=" + filepath.ToSlash(alicornRoot)
	if err := generateScratchpadThemes(root, alicornRoot, buildDir, odinExe, collectionArg); err != nil {
		return err
	}
	accessKitFlags, err := accessKitLinkerFlags(alicornRoot)
	if err != nil {
		return err
	}
	frontendEnv := buildEnv
	if runtime.GOOS == "darwin" {
		frontendEnv = setEnv(frontendEnv, "MACOSX_DEPLOYMENT_TARGET", "13.0")
		frontendEnv, err = prepareNativeFrontendEnvWithPrefix(frontendEnv, filepath.Dir(filepath.Dir(macSDLRuntime)))
	} else {
		frontendEnv, err = prepareNativeFrontendEnv(root, buildEnv)
	}
	if err != nil {
		return err
	}
	executable, err := buildFrontend(root, buildDir, odinExe, collectionArg, accessKitFlags, true, true, frontendEnv)
	if err != nil {
		return err
	}

	goModules, licenseNames, err := stageConsumerLicenses(root, alicornRoot, caliberRoot, goExe, odinExe, buildDir, macSDLLicense)
	if err != nil {
		return err
	}
	metadata := packageMetadata{
		Name: "Scratchpad", Version: version,
		BundleIdentifier: "com.samanshaiza004.scratchpad",
		ExecutableName:   "Scratchpad", MinimumMacOSVersion: "13.0",
		Resources:        nativePackageResources(runtime.GOOS, licenseNames),
		PrivateLibraries: []string{backendLibraryName(), filepath.Base(caliberLibrary)},
	}
	metadataBytes, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return err
	}
	metadataPath := filepath.Join(buildDir, "scratchpad-package.json")
	if err := os.WriteFile(metadataPath, append(metadataBytes, '\n'), 0o644); err != nil {
		return err
	}

	revision, err := gitOutput(root, "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	manifest := scratchpadBuildManifest{
		Schema:       1,
		Application:  releaseApp{Name: "Scratchpad", Version: version, Executable: "Scratchpad"},
		Source:       releaseSource{Scratchpad: strings.TrimSpace(revision), Alicorn: lockedRevision(root, "alicorn"), Caliber: lockedRevision(root, "caliber")},
		Target:       releaseTarget{OS: runtime.GOOS, Architecture: runtime.GOARCH, WindowsGUI: runtime.GOOS == "windows", MacAdHocSigned: runtime.GOOS == "darwin", Notarized: false},
		Dependencies: releaseDeps{GoModules: goModules},
		Licenses:     licenseNames,
	}
	appExecutable, err := assembleConsumerPackage(root, alicornRoot, odinExe, executable, buildDir, appDir, metadataPath, manifest, version, macSDLRuntime)
	if err != nil {
		return err
	}
	manifest.Dependencies.SDL3, err = readSDLPackageMetadata(filepath.Join(appDir, "alicorn-package.json"))
	if err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		if err := consumerPackageSmoke(root, appExecutable, staging); err != nil {
			return err
		}
	}
	manifest.Validation = releaseValidation{
		NativeDependencyAudit:  "passed",
		RelocatedArchiveLaunch: "passed",
	}
	if runtime.GOOS == "darwin" {
		manifest.Validation.CodeSignatureVerification = "passed"
	}
	if err := writePackageBuildManifest(appDir, manifest); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		bundle := filepath.Join(appDir, "Scratchpad.app")
		if err := signAndVerifyMacBundle(bundle); err != nil {
			return err
		}
		if err := consumerPackageSmoke(root, filepath.Join(bundle, "Contents", "MacOS", "Scratchpad"), staging); err != nil {
			return err
		}
	}
	archiveName := fmt.Sprintf("Scratchpad-v%s-%s-%s.zip", version, runtime.GOOS, runtime.GOARCH)
	archivePath := filepath.Join(staging, archiveName)
	if runtime.GOOS == "windows" {
		if err := zipDirectory(appDir, archivePath, "Scratchpad"); err != nil {
			return err
		}
		if err := verifyWindowsGuiSubsystem(filepath.Join(appDir, "Scratchpad.exe")); err != nil {
			return err
		}
		if err := windowsArchiveSmoke(root, archivePath, staging); err != nil {
			return err
		}
	} else {
		bundle := filepath.Join(appDir, "Scratchpad.app")
		if err := runCommand(root, nil, "create macOS app ZIP", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, archivePath); err != nil {
			return err
		}
		if err := macArchiveSmoke(root, archivePath, staging); err != nil {
			return err
		}
	}
	archiveInfo, err := os.Stat(archivePath)
	if err != nil {
		return err
	}
	archiveHash, err := fileSHA256(archivePath)
	if err != nil {
		return err
	}
	artifacts := []releaseArtifact{{Name: archiveName, SHA256: archiveHash, Size: archiveInfo.Size()}}
	manifest.Validation.RelocatedArchiveLaunch = "passed"
	manifestBytes, err := json.MarshalIndent(makeReleaseManifest(manifest, artifacts), "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(staging, "release-manifest.json"), append(manifestBytes, '\n'), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(staging, "SHA256SUMS.txt"), []byte(fmt.Sprintf("%s  %s\n", archiveHash, archiveName)), 0o644); err != nil {
		return err
	}
	if err := os.RemoveAll(buildDir); err != nil {
		return fmt.Errorf("remove temporary package build files: %w", err)
	}
	if err := os.WriteFile(filepath.Join(staging, ".scratchpad-package-output"), []byte(packageOutputMarker), 0o600); err != nil {
		return err
	}
	return publishPackageDirectory(output, staging)
}

func validPackageVersion(version string) bool {
	parts := strings.Split(version, ".")
	if len(parts) != 3 {
		return false
	}
	for _, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return false
		}
		for _, r := range part {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}

func safePackageOutput(root, output string) (string, error) {
	root, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	outRoot, err := filepath.Abs(filepath.Join(root, "out"))
	if err != nil {
		return "", err
	}
	output, err = filepath.Abs(output)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(outRoot, output)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("package output must be a child of %s", outRoot)
	}
	if evalRoot, evalErr := filepath.EvalSymlinks(outRoot); evalErr == nil {
		parent := filepath.Dir(output)
		if evalParent, parentErr := filepath.EvalSymlinks(parent); parentErr == nil {
			evalRel, relErr := filepath.Rel(evalRoot, evalParent)
			if relErr != nil || evalRel == ".." || strings.HasPrefix(evalRel, ".."+string(filepath.Separator)) {
				return "", errors.New("package output resolves outside the repository out directory")
			}
		}
	}
	return output, nil
}

func validateReplaceablePackageOutput(output string) error {
	info, err := os.Stat(output)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("package output exists and is not a directory: %s", output)
	}
	marker, err := os.ReadFile(filepath.Join(output, ".scratchpad-package-output"))
	if err != nil || string(marker) != packageOutputMarker {
		return fmt.Errorf("refusing to replace non-Scratchpad package output at %s", output)
	}
	return nil
}

func publishPackageDirectory(output, staging string) error {
	backup := ""
	if _, err := os.Stat(output); err == nil {
		backup = output + ".previous-" + fmt.Sprint(time.Now().UnixNano())
		if err := os.Rename(output, backup); err != nil {
			return err
		}
	}
	if err := os.Rename(staging, output); err != nil {
		if backup != "" {
			_ = os.Rename(backup, output)
		}
		return err
	}
	if backup != "" {
		if err := os.RemoveAll(backup); err != nil {
			return fmt.Errorf("package published, but previous generated output cleanup failed: %w", err)
		}
	}
	fmt.Println("Verified consumer package:", output)
	return nil
}

func lockedRevision(root, dependency string) string {
	lock, err := readLock(root)
	if err != nil {
		return "unknown"
	}
	if dependency == "alicorn" {
		return lock.Alicorn.Revision
	}
	if dependency == "caliber" {
		return lock.Caliber.Revision
	}
	return "unknown"
}

func stageConsumerLicenses(root, alicornRoot, caliberRoot, goExe, odinExe, buildDir, macSDLLicense string) ([]goModuleLicense, []string, error) {
	licenseSources := []licenseSource{
		{name: "Scratchpad-LICENSE.txt", path: filepath.Join(root, "LICENSE")},
		{name: "Alicorn-LICENSE.txt", path: filepath.Join(alicornRoot, "LICENSE")},
		{name: "Runa-LICENSE.txt", path: filepath.Join(alicornRoot, "third_party", "Runa", "LICENSE")},
		{name: "Caliber-LICENSE-APACHE.txt", path: filepath.Join(caliberRoot, "LICENSE-APACHE")},
		{name: "Caliber-LICENSE-MIT.txt", path: filepath.Join(caliberRoot, "LICENSE-MIT")},
		{name: "AccessKit-LICENSE-APACHE.txt", path: filepath.Join(alicornRoot, ".deps", "accesskit", "accesskit-c-0.23.1", "LICENSE-APACHE")},
		{name: "AccessKit-LICENSE-MIT.txt", path: filepath.Join(alicornRoot, ".deps", "accesskit", "accesskit-c-0.23.1", "LICENSE-MIT")},
		{name: "Odin-LICENSE.txt", path: filepath.Join(filepath.Dir(odinExe), "LICENSE")},
	}
	if runtime.GOOS == "darwin" {
		licenseSources = append(licenseSources, licenseSource{name: "SDL-LICENSE.txt", path: macSDLLicense})
	} else {
		licenseSources = append(licenseSources, licenseSource{name: "SDL-LICENSE.txt", path: filepath.Join(root, "packaging", "SDL-LICENSE.txt")})
	}
	goroot, err := commandOutput(root, goExe, "env", "GOROOT")
	if err != nil {
		return nil, nil, fmt.Errorf("locate Go toolchain license: %w", err)
	}
	licenseSources = append(licenseSources, licenseSource{name: "Go-LICENSE.txt", path: filepath.Join(strings.TrimSpace(string(goroot)), "LICENSE")})
	if rustRoot, rustErr := commandOutput(root, "rustc", "--print", "sysroot"); rustErr == nil {
		rustLicenses := filepath.Join(strings.TrimSpace(string(rustRoot)), "share", "doc", "rust", "licenses")
		for _, name := range []string{"LICENSE-APACHE", "LICENSE-MIT"} {
			path := filepath.Join(rustLicenses, name)
			if _, statErr := os.Stat(path); statErr == nil {
				licenseSources = append(licenseSources, licenseSource{name: "Rust-" + name + ".txt", path: path})
			}
		}
	}

	modules, err := goRuntimeModules(root, goExe)
	if err != nil {
		return nil, nil, err
	}
	moduleLicenses := make([]goModuleLicense, 0, len(modules))
	for _, module := range modules {
		files, err := moduleLicenseFiles(module.dir)
		if err != nil {
			return nil, nil, fmt.Errorf("find license for Go module %s@%s: %w", module.path, module.version, err)
		}
		entry := goModuleLicense{Path: module.path, Version: module.version}
		for _, source := range files {
			name := "Go-" + safeFilePart(module.path) + "-" + safeFilePart(module.version) + "-" + source
			licenseSources = append(licenseSources, licenseSource{name: name, path: filepath.Join(module.dir, source)})
			entry.Licenses = append(entry.Licenses, "licenses/"+name)
		}
		moduleLicenses = append(moduleLicenses, entry)
	}

	licenseDir := filepath.Join(buildDir, "licenses")
	if err := os.MkdirAll(licenseDir, 0o755); err != nil {
		return nil, nil, err
	}
	resources := make([]string, 0, len(licenseSources))
	seen := make(map[string]bool, len(licenseSources))
	for _, source := range licenseSources {
		if seen[source.name] {
			return nil, nil, fmt.Errorf("duplicate packaged license name %q", source.name)
		}
		seen[source.name] = true
		data, err := os.ReadFile(source.path)
		if err != nil {
			return nil, nil, fmt.Errorf("read required license %s: %w", source.path, err)
		}
		if len(data) == 0 {
			return nil, nil, fmt.Errorf("required license is empty: %s", source.path)
		}
		if err := os.WriteFile(filepath.Join(licenseDir, source.name), data, 0o644); err != nil {
			return nil, nil, err
		}
		resources = append(resources, "licenses/"+source.name)
	}
	sort.Strings(resources)
	sort.Slice(moduleLicenses, func(i, j int) bool { return moduleLicenses[i].Path < moduleLicenses[j].Path })
	return moduleLicenses, resources, nil
}

func goRuntimeModules(root, goExe string) ([]moduleRecord, error) {
	format := `{{if .Module}}{{.Module.Path}}|{{.Module.Version}}|{{.Module.Dir}}{{end}}`
	output, err := commandOutput(root, goExe, "list", "-deps", "-f", format, "-tags", "treesitter_release", "./...")
	if err != nil {
		return nil, fmt.Errorf("enumerate Go runtime dependencies for license notices: %w", err)
	}
	byModule := make(map[string]moduleRecord)
	for _, line := range strings.Split(string(output), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), "|", 3)
		if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[0] == "scratchpad" {
			continue
		}
		key := parts[0] + "@" + parts[1]
		byModule[key] = moduleRecord{path: parts[0], version: parts[1], dir: parts[2]}
	}
	modules := make([]moduleRecord, 0, len(byModule))
	for _, module := range byModule {
		modules = append(modules, module)
	}
	sort.Slice(modules, func(i, j int) bool {
		if modules[i].path == modules[j].path {
			return modules[i].version < modules[j].version
		}
		return modules[i].path < modules[j].path
	})
	return modules, nil
}

// nativePackageResources omits licenses that Alicorn's platform packagers
// place in the app's resource directory from explicit arguments. macOS rejects
// duplicate basenames when it copies generic resources into that directory.
func nativePackageResources(goos string, resources []string) []string {
	if goos != "darwin" {
		return resources
	}
	packagerOwned := map[string]bool{
		"licenses/SDL-LICENSE.txt":              true,
		"licenses/AccessKit-LICENSE-APACHE.txt": true,
		"licenses/AccessKit-LICENSE-MIT.txt":    true,
	}
	filtered := make([]string, 0, len(resources))
	for _, resource := range resources {
		if !packagerOwned[resource] {
			filtered = append(filtered, resource)
		}
	}
	return filtered
}

func moduleLicenseFiles(moduleDir string) ([]string, error) {
	entries, err := os.ReadDir(moduleDir)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		upper := strings.ToUpper(name)
		if strings.HasPrefix(upper, "LICENSE") || strings.HasPrefix(upper, "COPYING") || strings.HasPrefix(upper, "NOTICE") {
			files = append(files, name)
		}
	}
	sort.Strings(files)
	if len(files) == 0 {
		return nil, errors.New("no top-level LICENSE, COPYING, or NOTICE file")
	}
	return files, nil
}

func buildPinnedMacSDL(root, buildDir string) (runtimeLibrary, license string, err error) {
	if runtime.GOOS != "darwin" {
		return "", "", errors.New("pinned macOS SDL can only be built on macOS")
	}
	sdlRoot := filepath.Join(buildDir, "sdl-"+macSDLVersion)
	archive := filepath.Join(sdlRoot, "SDL3-"+macSDLVersion+".tar.gz")
	source := filepath.Join(sdlRoot, "source")
	cmakeBuild := filepath.Join(sdlRoot, "build")
	prefix := filepath.Join(sdlRoot, "prefix")
	if err := os.MkdirAll(sdlRoot, 0o755); err != nil {
		return "", "", err
	}
	if _, err := os.Stat(archive); errors.Is(err, os.ErrNotExist) {
		if err := runCommand(root, nil, "download pinned SDL source", "curl", "-fL", "--retry", "3", "--connect-timeout", "20", "--max-time", "180", macSDLSource, "-o", archive); err != nil {
			return "", "", err
		}
	} else if err != nil {
		return "", "", err
	}
	actualHash, err := fileSHA256(archive)
	if err != nil {
		return "", "", err
	}
	if actualHash != macSDLSourceSHA256 {
		return "", "", fmt.Errorf("pinned SDL source checksum mismatch: got %s", actualHash)
	}
	if _, err := os.Stat(filepath.Join(source, "CMakeLists.txt")); errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(source, 0o755); err != nil {
			return "", "", err
		}
		if err := runCommand(root, nil, "extract pinned SDL source", "tar", "-xzf", archive, "--strip-components=1", "-C", source); err != nil {
			return "", "", err
		}
	} else if err != nil {
		return "", "", err
	}
	version, err := readSDLSourceVersion(filepath.Join(source, "include", "SDL3", "SDL_version.h"))
	if err != nil {
		return "", "", err
	}
	if version != macSDLVersion {
		return "", "", fmt.Errorf("pinned SDL source declares version %s, expected %s", version, macSDLVersion)
	}
	configure := []string{
		"-S", source, "-B", cmakeBuild,
		"-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=" + prefix,
		"-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0",
		"-DSDL_SHARED=ON", "-DSDL_STATIC=OFF", "-DSDL_TEST_LIBRARY=OFF",
		"-DSDL_TESTS=OFF", "-DSDL_INSTALL_TESTS=OFF", "-DSDL_DISABLE_INSTALL_DOCS=ON",
		"-DSDL_FRAMEWORK=OFF", "-DSDL_RPATH=OFF",
	}
	if err := runCommand(root, nil, "configure pinned shared SDL", "cmake", configure...); err != nil {
		return "", "", err
	}
	if err := runCommand(root, nil, "build pinned shared SDL", "cmake", "--build", cmakeBuild, "--config", "Release", "--target", "SDL3-shared"); err != nil {
		return "", "", err
	}
	if err := runCommand(root, nil, "install pinned shared SDL", "cmake", "--install", cmakeBuild, "--config", "Release"); err != nil {
		return "", "", err
	}
	runtimeLibrary = filepath.Join(prefix, "lib", "libSDL3.dylib")
	if _, err := os.Stat(runtimeLibrary); err != nil {
		return "", "", fmt.Errorf("pinned SDL runtime was not installed at %s: %w", runtimeLibrary, err)
	}
	license = filepath.Join(source, "LICENSE.txt")
	if _, err := os.Stat(license); err != nil {
		return "", "", fmt.Errorf("pinned SDL source has no license file: %w", err)
	}
	return runtimeLibrary, license, nil
}

func readSDLSourceVersion(path string) (string, error) {
	header, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read SDL version header: %w", err)
	}
	pattern := regexp.MustCompile(`(?m)^#define SDL_(MAJOR|MINOR|MICRO)_VERSION\s+([0-9]+)\s*$`)
	parts := map[string]string{}
	for _, match := range pattern.FindAllSubmatch(header, -1) {
		parts[string(match[1])] = string(match[2])
	}
	if parts["MAJOR"] == "" || parts["MINOR"] == "" || parts["MICRO"] == "" {
		return "", errors.New("SDL version header is missing a major, minor, or micro version")
	}
	return parts["MAJOR"] + "." + parts["MINOR"] + "." + parts["MICRO"], nil
}

func safeFilePart(value string) string {
	replacer := strings.NewReplacer("/", "-", "\\", "-", ".", "-", "@", "-", " ", "-")
	value = replacer.Replace(value)
	var builder strings.Builder
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			builder.WriteRune(r)
		}
	}
	return strings.Trim(builder.String(), "-_")
}

func assembleConsumerPackage(root, alicornRoot, odinExe, executable, buildDir, appDir, metadataPath string, manifest scratchpadBuildManifest, version, macSDLRuntime string) (string, error) {
	sdlLicense := filepath.Join(buildDir, "licenses", "SDL-LICENSE.txt")
	accessKitApache := filepath.Join(buildDir, "licenses", "AccessKit-LICENSE-APACHE.txt")
	accessKitMIT := filepath.Join(buildDir, "licenses", "AccessKit-LICENSE-MIT.txt")
	if runtime.GOOS == "windows" {
		powershell := "powershell.exe"
		if found, err := exec.LookPath("pwsh.exe"); err == nil {
			powershell = found
		}
		args := []string{
			"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(alicornRoot, "tools", "package_app.ps1"),
			"-Executable", executable, "-Metadata", metadataPath, "-SDLLinkage", "Shared",
			"-SDLRuntime", filepath.Join(buildDir, "SDL3.dll"), "-SDLLicense", sdlLicense,
			"-AccessKitLicenseApache", accessKitApache, "-AccessKitLicenseMIT", accessKitMIT,
			"-OutputDirectory", appDir,
		}
		if err := runCommand(root, nil, "Alicorn Windows dependency package audit", powershell, args...); err != nil {
			return "", err
		}
		packagedExe := filepath.Join(appDir, "Scratchpad.exe")
		if err := verifyWindowsGuiSubsystem(packagedExe); err != nil {
			return "", err
		}
		return packagedExe, nil
	}

	args := []string{
		filepath.Join(alicornRoot, "tools", "package_macos.py"),
		"--executable", executable, "--metadata", metadataPath, "--linkage", "shared",
		"--sdl-version", macSDLVersion, "--sdl-runtime", macSDLRuntime, "--sdl-license", sdlLicense,
		"--accesskit-license-apache", accessKitApache, "--accesskit-license-mit", accessKitMIT,
		"--output", appDir,
	}
	if err := runCommand(root, nil, "Alicorn macOS dependency package audit", "python3", args...); err != nil {
		return "", err
	}
	bundle := filepath.Join(appDir, "Scratchpad.app")
	packageManifest := filepath.Join(appDir, "alicorn-package.json")
	if err := copyPackageFile(packageManifest, filepath.Join(bundle, "Contents", "Resources", "alicorn-package.json")); err != nil {
		return "", err
	}
	return filepath.Join(bundle, "Contents", "MacOS", "Scratchpad"), nil
}

func verifyWindowsGuiSubsystem(executable string) error {
	image, err := pe.Open(executable)
	if err != nil {
		return fmt.Errorf("inspect Windows package executable: %w", err)
	}
	defer image.Close()
	subsystem := uint16(0)
	switch header := image.OptionalHeader.(type) {
	case *pe.OptionalHeader32:
		subsystem = header.Subsystem
	case *pe.OptionalHeader64:
		subsystem = header.Subsystem
	default:
		return errors.New("Windows package executable has an unsupported PE optional header")
	}
	if subsystem != 2 {
		return fmt.Errorf("Windows consumer executable uses PE subsystem %d, want Windows GUI (2)", subsystem)
	}
	return nil
}

func signAndVerifyMacBundle(bundle string) error {
	if err := runCommand(".", nil, "apply ad-hoc macOS code signature", "codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", bundle); err != nil {
		return err
	}
	return runCommand(".", nil, "verify macOS app signature", "codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle)
}

func writePackageBuildManifest(appDir string, manifest scratchpadBuildManifest) error {
	path := filepath.Join(appDir, "scratchpad-build-manifest.json")
	if runtime.GOOS == "darwin" {
		path = filepath.Join(appDir, "Scratchpad.app", "Contents", "Resources", "scratchpad-build-manifest.json")
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		return err
	}
	readme := "Scratchpad consumer package. See scratchpad-build-manifest.json and alicorn-package.json for build identity, dependencies, audit results, and licenses.\n"
	readmePath := filepath.Join(appDir, "README-RELEASE.txt")
	if runtime.GOOS == "darwin" {
		readmePath = filepath.Join(appDir, "Scratchpad.app", "Contents", "Resources", "README-RELEASE.txt")
	}
	return os.WriteFile(readmePath, []byte(readme), 0o644)
}

func consumerPackageSmoke(root, executable, tempParent string) error {
	smokeRoot, err := os.MkdirTemp(tempParent, ".relocated-smoke-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(smokeRoot)
	workDir := filepath.Join(smokeRoot, "unrelated-working-directory")
	configDir := filepath.Join(smokeRoot, "config")
	if err := os.MkdirAll(workDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return err
	}
	env := os.Environ()
	env = setEnv(env, "SCRATCHPAD_ALICORN_SMOKE", "1")
	env = setEnv(env, "SCRATCHPAD_ALICORN_WORKSPACE", workDir)
	env = setEnv(env, "SCRATCHPAD_DISABLE_RECOVERY", "1")
	env = setEnv(env, "SCRATCHPAD_DISABLE_SESSION", "1")
	if runtime.GOOS == "windows" {
		env = setEnv(env, "APPDATA", configDir)
		env = setEnv(env, "LOCALAPPDATA", configDir)
		env = setEnv(env, "USERPROFILE", smokeRoot)
	} else {
		env = setEnv(env, "HOME", smokeRoot)
		env = setEnv(env, "XDG_CONFIG_HOME", configDir)
	}
	if err := runCommandWithTimeout(workDir, env, 30*time.Second, executable); err != nil {
		startupLog := filepath.Join(configDir, "Scratchpad", "startup.log")
		if runtime.GOOS == "darwin" {
			startupLog = filepath.Join(smokeRoot, "Library", "Application Support", "Scratchpad", "startup.log")
		}
		if data, readErr := os.ReadFile(startupLog); readErr == nil && len(data) != 0 {
			return fmt.Errorf("consumer launch from unrelated directory: %w\nstartup log (%s):\n%s", err, startupLog, strings.TrimSpace(string(data)))
		}
		return fmt.Errorf("consumer launch from unrelated directory: %w", err)
	}
	return nil
}

func zipDirectory(sourceDir, destination, topLevel string) error {
	file, err := os.Create(destination)
	if err != nil {
		return err
	}
	writer := zip.NewWriter(file)
	walkErr := filepath.WalkDir(sourceDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(sourceDir, path)
		if err != nil {
			return err
		}
		name := topLevel
		if rel != "." {
			name = filepath.ToSlash(filepath.Join(topLevel, rel))
		}
		if info.IsDir() {
			name += "/"
		}
		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		header.Name = name
		if !info.IsDir() {
			header.Method = zip.Deflate
		}
		output, err := writer.CreateHeader(header)
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		input, err := os.Open(path)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(output, input)
		closeErr := input.Close()
		if copyErr != nil {
			return copyErr
		}
		return closeErr
	})
	writerErr := writer.Close()
	fileErr := file.Close()
	if walkErr != nil {
		return walkErr
	}
	if writerErr != nil {
		return writerErr
	}
	return fileErr
}

func unzipArchive(source, destination string) error {
	reader, err := zip.OpenReader(source)
	if err != nil {
		return err
	}
	defer reader.Close()
	root, err := filepath.Abs(destination)
	if err != nil {
		return err
	}
	for _, item := range reader.File {
		clean := filepath.Clean(filepath.FromSlash(item.Name))
		if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return fmt.Errorf("unsafe path in package archive: %s", item.Name)
		}
		path := filepath.Join(root, clean)
		if item.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		input, err := item.Open()
		if err != nil {
			return err
		}
		mode := item.Mode().Perm()
		if mode == 0 {
			mode = 0o644
		}
		output, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
		if err != nil {
			input.Close()
			return err
		}
		_, copyErr := io.Copy(output, input)
		closeOutErr := output.Close()
		closeInErr := input.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeOutErr != nil {
			return closeOutErr
		}
		if closeInErr != nil {
			return closeInErr
		}
	}
	return nil
}

func windowsArchiveSmoke(root, archive string, tempParent string) error {
	extractDir, err := os.MkdirTemp(tempParent, ".zip-smoke-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(extractDir)
	if err := unzipArchive(archive, extractDir); err != nil {
		return err
	}
	executable := filepath.Join(extractDir, "Scratchpad", "Scratchpad.exe")
	if err := verifyWindowsGuiSubsystem(executable); err != nil {
		return err
	}
	return consumerPackageSmoke(root, executable, tempParent)
}

func macArchiveSmoke(root, archive string, tempParent string) error {
	extractDir, err := os.MkdirTemp(tempParent, ".zip-smoke-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(extractDir)
	if err := runCommand(root, nil, "extract macOS app ZIP for relocation smoke", "ditto", "-x", "-k", archive, extractDir); err != nil {
		return err
	}
	bundle := filepath.Join(extractDir, "Scratchpad.app")
	if err := runCommand(root, nil, "verify extracted macOS app signature", "codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle); err != nil {
		return err
	}
	return consumerPackageSmoke(root, filepath.Join(bundle, "Contents", "MacOS", "Scratchpad"), tempParent)
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func copyPackageFile(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	return os.WriteFile(destination, data, 0o644)
}

func makeReleaseManifest(manifest scratchpadBuildManifest, artifacts []releaseArtifact) releaseManifest {
	return releaseManifest{
		Schema: manifest.Schema, Application: manifest.Application, Source: manifest.Source,
		Target: manifest.Target, Dependencies: manifest.Dependencies, Licenses: manifest.Licenses,
		Validation: manifest.Validation, Artifacts: artifacts,
	}
}

func readSDLPackageMetadata(path string) (releaseSDL, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return releaseSDL{}, err
	}
	var packageManifest struct {
		Host struct {
			SDLVersion string `json:"sdlVersion"`
			SDLLinkage string `json:"sdlLinkage"`
		} `json:"host"`
	}
	if err := json.Unmarshal(data, &packageManifest); err != nil {
		return releaseSDL{}, fmt.Errorf("decode Alicorn native package manifest: %w", err)
	}
	if packageManifest.Host.SDLVersion == "" || packageManifest.Host.SDLLinkage == "" {
		return releaseSDL{}, errors.New("Alicorn package manifest is missing its SDL version or linkage")
	}
	return releaseSDL{Version: packageManifest.Host.SDLVersion, Linkage: packageManifest.Host.SDLLinkage}, nil
}

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type macHashEntry struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
}

// Preserve Alicorn-owned metadata while updating the hashes Scratchpad changes
// through final signing. The executable hash lives outside its own signed seal.
func refreshMacPackageHashes(bundle string) error {
	path := filepath.Join(filepath.Dir(bundle), "alicorn-package.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var manifest map[string]json.RawMessage
	if err := json.Unmarshal(data, &manifest); err != nil {
		return err
	}
	var application, dependencies map[string]json.RawMessage
	if err := json.Unmarshal(manifest["application"], &application); err != nil {
		return err
	}
	if err := json.Unmarshal(manifest["dependencies"], &dependencies); err != nil {
		return err
	}
	var bundled []macHashEntry
	if err := json.Unmarshal(dependencies["bundled"], &bundled); err != nil {
		return err
	}
	for i := range bundled {
		image, err := macBundleFile(bundle, bundled[i].Name)
		if err != nil {
			return err
		}
		bundled[i].SHA256, err = fileSHA256(image)
		if err != nil {
			return err
		}
	}
	resources := []macHashEntry{}
	resourceDir := filepath.Join(bundle, "Contents", "Resources")
	err = filepath.WalkDir(resourceDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || path == filepath.Join(resourceDir, "alicorn-package.json") {
			return nil
		}
		rel, err := filepath.Rel(bundle, path)
		if err != nil {
			return err
		}
		hash, err := fileSHA256(path)
		if err != nil {
			return err
		}
		resources = append(resources, macHashEntry{Name: filepath.ToSlash(rel), SHA256: hash})
		return nil
	})
	if err != nil {
		return err
	}
	delete(application, "sha256")
	application["sha256Manifest"] = json.RawMessage(`"release-manifest.json#signedImages"`)
	application["resources"], err = json.Marshal(resources)
	if err != nil {
		return err
	}
	dependencies["bundled"], err = json.Marshal(bundled)
	if err != nil {
		return err
	}
	manifest["application"], err = json.Marshal(application)
	if err != nil {
		return err
	}
	manifest["dependencies"], err = json.Marshal(dependencies)
	if err != nil {
		return err
	}
	data, err = json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(resourceDir, "alicorn-package.json"), data, 0o644)
}

func macBundleFile(bundle, name string) (string, error) {
	if name == "" || filepath.IsAbs(name) {
		return "", fmt.Errorf("invalid bundle-relative image path %q", name)
	}
	path := filepath.Join(bundle, filepath.FromSlash(name))
	rel, err := filepath.Rel(bundle, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("image path escapes macOS bundle: %q", name)
	}
	return path, nil
}

func macPackageImagePaths(bundle string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(bundle, "Contents", "Resources", "alicorn-package.json"))
	if err != nil {
		return nil, err
	}
	var manifest struct {
		Application struct {
			Executable string `json:"executable"`
		} `json:"application"`
		Dependencies struct {
			Bundled []macHashEntry `json:"bundled"`
		} `json:"dependencies"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, err
	}
	names := []string{manifest.Application.Executable}
	for _, entry := range manifest.Dependencies.Bundled {
		names = append(names, entry.Name)
	}
	paths := make([]string, 0, len(names))
	for _, name := range names {
		path, err := macBundleFile(bundle, name)
		if err != nil {
			return nil, err
		}
		paths = append(paths, path)
	}
	return paths, nil
}

func signedMacPackageImages(bundle string) ([]releaseArtifact, error) {
	paths, err := macPackageImagePaths(bundle)
	if err != nil {
		return nil, err
	}
	images := make([]releaseArtifact, 0, len(paths))
	for _, path := range paths {
		rel, err := filepath.Rel(filepath.Dir(bundle), path)
		if err != nil {
			return nil, err
		}
		hash, err := fileSHA256(path)
		if err != nil {
			return nil, err
		}
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		images = append(images, releaseArtifact{Name: filepath.ToSlash(rel), SHA256: hash, Size: info.Size()})
	}
	return images, nil
}

func verifyMacPackageHashes(bundle string) error {
	data, err := os.ReadFile(filepath.Join(bundle, "Contents", "Resources", "alicorn-package.json"))
	if err != nil {
		return err
	}
	var manifest struct {
		Application struct {
			SHA256    string         `json:"sha256"`
			Resources []macHashEntry `json:"resources"`
		} `json:"application"`
		Dependencies struct {
			Bundled []macHashEntry `json:"bundled"`
		} `json:"dependencies"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return err
	}
	if manifest.Application.SHA256 != "" {
		return fmt.Errorf("embedded executable hash would refer to its own macOS signature seal")
	}
	for _, entry := range append(manifest.Dependencies.Bundled, manifest.Application.Resources...) {
		path, err := macBundleFile(bundle, entry.Name)
		if err != nil {
			return err
		}
		hash, err := fileSHA256(path)
		if err != nil {
			return err
		}
		if hash != entry.SHA256 {
			return fmt.Errorf("final macOS package hash mismatch for %s: recorded %s, actual %s", entry.Name, entry.SHA256, hash)
		}
	}
	return nil
}

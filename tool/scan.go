package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

const chunkSize = 300

type PluginManifest struct {
	Name        string `yaml:"name"`
	Version     string `yaml:"version"`
	Author      string `yaml:"author"`
	Description string `yaml:"description"`
}

type PluginEntry struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	Author      string `json:"author"`
	Description string `json:"description"`
	Path        string `json:"path"`
	Image       string `json:"image,omitempty"`
}

type PluginsIndex struct {
	Total  int      `json:"total"`
	Chunks []string `json:"chunks"`
}

func cmdScan(args []string) {
	pDir := pluginsDir()
	mDir := metadataDir()
	os.MkdirAll(mDir, 0755)

	fmt.Println("🔍 正在扫描插件仓库...")

	var entries []PluginEntry
	filepath.Walk(pDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || !info.IsDir() || path == pDir {
			return nil
		}
		data, err := os.ReadFile(filepath.Join(path, "pluggin.yaml"))
		if err != nil {
			return nil
		}
		var m PluginManifest
		if yaml.Unmarshal(data, &m) != nil {
			return nil
		}
		rel, _ := filepath.Rel(pDir, path)
		e := PluginEntry{
			Name: m.Name, Version: m.Version,
			Author: m.Author, Description: m.Description,
			Path: rel,
		}
		for _, img := range []string{"logo.png", "logo.jpg", "icon.png"} {
			if _, err := os.Stat(filepath.Join(path, img)); err == nil {
				e.Image = filepath.Join(rel, img)
				break
			}
		}
		entries = append(entries, e)
		fmt.Printf("   ✓ %s (%s)\n", filepath.Base(path), m.Version)
		return filepath.SkipDir
	})

	sort.Slice(entries, func(i, j int) bool {
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})

	chunks := int(math.Ceil(float64(len(entries)) / float64(chunkSize)))
	var chunkFiles []string

	for i := 0; i < chunks; i++ {
		end := (i + 1) * chunkSize
		if end > len(entries) {
			end = len(entries)
		}
		cn := fmt.Sprintf("chunk_%d.json", i+1)
		data, _ := json.MarshalIndent(entries[i*chunkSize:end], "", "  ")
		os.WriteFile(filepath.Join(mDir, cn), data, 0644)
		chunkFiles = append(chunkFiles, cn)
	}

	idx := PluginsIndex{Total: len(entries), Chunks: chunkFiles}
	idxData, _ := json.MarshalIndent(idx, "", "  ")
	os.WriteFile(filepath.Join(repoRoot(), "plugins.json"), idxData, 0644)

	fmt.Printf("\n✅ 扫描完成!\n   📊 %d 个插件, %d 个分片\n", len(entries), chunks)
}

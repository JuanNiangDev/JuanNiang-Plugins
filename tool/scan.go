package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
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

var scanCmd = &cobra.Command{
	Use:   "scan",
	Short: "扫描插件并更新元数据",
	Long:  "遍历 plugins/ 目录，读取所有 pluggin.yaml，生成分片元数据到 metadata/ 目录并更新 plugins.json 索引。",
	Args:  cobra.NoArgs,
	RunE:  runScan,
}

func runScan(cmd *cobra.Command, args []string) error {
	pDir := pluginsDir()
	mDir := metadataDir()
	os.MkdirAll(mDir, 0755)

	fmt.Println(color.CyanString("🔍 正在扫描插件仓库..."))

	var entries []PluginEntry
	err := filepath.Walk(pDir, func(path string, info os.FileInfo, err error) error {
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
		fmt.Printf("   %s %s (%s)\n", color.GreenString("✓"), color.CyanString(filepath.Base(path)), m.Version)
		return filepath.SkipDir
	})
	if err != nil {
		return fmt.Errorf("扫描失败: %w", err)
	}

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

	fmt.Println()
	fmt.Println(color.GreenString("✅ 扫描完成!"))
	fmt.Printf("   📊 %d 个插件, %d 个分片\n", len(entries), chunks)
	return nil
}

package main

import (
	"os"
	"path/filepath"
)

// repoRoot 返回 JuanNiang-Plugins 仓库根目录（绝对路径）。
// 查找逻辑：从可执行文件所在目录向上找包含 "plugins.json" 的目录。
func repoRoot() string {
	// 先尝试从可执行文件路径推导
	exe, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(exe)
		for {
			if _, err := os.Stat(filepath.Join(dir, "plugins.json")); err == nil {
				return dir
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	// 回退：从当前工作目录向上找
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "plugins.json")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "."
}

func pluginsDir() string  { return filepath.Join(repoRoot(), "plugins") }
func metadataDir() string { return filepath.Join(repoRoot(), "metadata") }
func templateDir() string { return filepath.Join(repoRoot(), "template") }
func sdkDir() string      { return filepath.Join(repoRoot(), "sdk") }

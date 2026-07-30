package main

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func cmdPack(args []string) {
	if len(args) < 1 {
		fmt.Println("❌ 用法: hago pack <插件名>")
		os.Exit(1)
	}
	name := args[0]

	srcDir := filepath.Join(pluginsDir(), name)
	if _, err := os.Stat(srcDir); os.IsNotExist(err) {
		fmt.Printf("❌ 插件目录不存在: %s\n", srcDir)
		os.Exit(1)
	}

	zipPath := filepath.Join(pluginsDir(), name+".zip")
	zipFile, err := os.Create(zipPath)
	if err != nil {
		fmt.Printf("❌ 创建 ZIP 失败: %v\n", err)
		os.Exit(1)
	}
	defer zipFile.Close()

	zw := zip.NewWriter(zipFile)
	defer zw.Close()

	fmt.Printf("📦 正在打包 %s ...\n", name)

	err = filepath.Walk(srcDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(srcDir, path)
		rel = strings.ReplaceAll(rel, string(filepath.Separator), "/")
		if strings.HasSuffix(rel, ".zip") {
			return nil
		}
		h := &zip.FileHeader{Name: filepath.Join(name, rel), Method: zip.Deflate}
		h.SetModTime(info.ModTime())
		w, _ := zw.CreateHeader(h)
		f, _ := os.Open(path)
		if f != nil {
			defer f.Close()
			io.Copy(w, f)
		}
		fmt.Printf("   ➕ %s\n", rel)
		return nil
	})
	if err != nil {
		fmt.Printf("❌ 打包失败: %v\n", err)
		os.Exit(1)
	}

	info, _ := os.Stat(zipPath)
	fmt.Printf("\n✅ 打包完成!\n   📦 %s (%.1f KB)\n", zipPath, float64(info.Size())/1024)
}

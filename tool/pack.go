package main

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
)

var packCmd = &cobra.Command{
	Use:   "pack <name>",
	Short: "将插件打包为 .zip",
	Long:  "将指定插件目录打包为 .zip 文件，方便分发和上传。",
	Args:  cobra.ExactArgs(1),
	RunE:  runPack,
}

func runPack(cmd *cobra.Command, args []string) error {
	name := args[0]

	srcDir := filepath.Join(pluginsDir(), name)
	if _, err := os.Stat(srcDir); os.IsNotExist(err) {
		return fmt.Errorf("插件目录不存在: %s", srcDir)
	}

	zipPath := filepath.Join(distDir(), name+".zip")
	os.MkdirAll(distDir(), 0755)
	zipFile, err := os.Create(zipPath)
	if err != nil {
		return fmt.Errorf("创建 ZIP 失败: %w", err)
	}
	defer zipFile.Close()

	zw := zip.NewWriter(zipFile)
	defer zw.Close()

	fmt.Printf("📦 正在打包 %s ...\n", color.CyanString(name))

	err = filepath.Walk(srcDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(srcDir, path)
		rel = strings.ReplaceAll(rel, string(filepath.Separator), "/")
		if strings.HasSuffix(rel, ".zip") {
			return nil
		}
		h := &zip.FileHeader{Name: rel, Method: zip.Deflate}
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
		return fmt.Errorf("打包失败: %w", err)
	}

	info, _ := os.Stat(zipPath)
	fmt.Println()
	fmt.Println(color.GreenString("✅ 打包完成!"))
	fmt.Printf("   📦 %s (%.1f KB)\n", color.CyanString(zipPath), float64(info.Size())/1024)
	return nil
}

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

var packAll bool

var packCmd = &cobra.Command{
	Use:   "pack <name|prefix*>",
	Short: "将插件打包为 .zip",
	Long:  "将指定插件目录打包为 .zip 文件。支持通配符（如 redrock_*）和 --all 全量打包。",
	Args:  cobra.MaximumNArgs(1),
	RunE:  runPack,
}

func init() {
	packCmd.Flags().BoolVarP(&packAll, "all", "a", false, "打包所有插件")
}

func runPack(cmd *cobra.Command, args []string) error {
	os.MkdirAll(distDir(), 0755)

	// --all: 打包所有
	if packAll {
		return packAllPlugins()
	}

	if len(args) == 0 {
		return fmt.Errorf("请指定插件名或使用 --all 打包全部")
	}

	name := args[0]

	// 通配符匹配
	if strings.HasSuffix(name, "*") {
		prefix := strings.TrimSuffix(name, "*")
		return packByPrefix(prefix)
	}

	return packOne(name)
}

func packAllPlugins() error {
	entries, err := os.ReadDir(pluginsDir())
	if err != nil {
		return fmt.Errorf("读取插件目录失败: %w", err)
	}

	var names []string
	for _, e := range entries {
		if e.IsDir() && e.Name() != "sdk" {
			names = append(names, e.Name())
		}
	}

	if len(names) == 0 {
		fmt.Println("📭 没有找到插件")
		return nil
	}

	fmt.Printf("📦 打包全部 %d 个插件...\n\n", len(names))
	for _, name := range names {
		if err := packOne(name); err != nil {
			fmt.Println(color.RedString("   ✖ %s: %s", name, err))
		}
	}
	fmt.Printf("\n" + color.GreenString("✅ 全部打包完成!"))
	fmt.Printf("   📁 %s\n", color.CyanString(distDir()))
	return nil
}

func packByPrefix(prefix string) error {
	entries, err := os.ReadDir(pluginsDir())
	if err != nil {
		return fmt.Errorf("读取插件目录失败: %w", err)
	}

	var names []string
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), prefix) {
			names = append(names, e.Name())
		}
	}

	if len(names) == 0 {
		return fmt.Errorf("没有匹配 '%s*' 的插件", prefix)
	}

	fmt.Printf("📦 打包 %d 个匹配 '%s*' 的插件...\n\n", len(names), prefix)
	for _, name := range names {
		if err := packOne(name); err != nil {
			fmt.Println(color.RedString("   ✖ %s: %s", name, err))
		}
	}
	fmt.Printf("\n" + color.GreenString("✅ 全部打包完成!"))
	fmt.Printf("   📁 %s\n", color.CyanString(distDir()))
	return nil
}

func packOne(name string) error {
	srcDir := filepath.Join(pluginsDir(), name)
	if _, err := os.Stat(srcDir); os.IsNotExist(err) {
		return fmt.Errorf("插件目录不存在: %s", srcDir)
	}

	zipPath := filepath.Join(distDir(), name+".zip")
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

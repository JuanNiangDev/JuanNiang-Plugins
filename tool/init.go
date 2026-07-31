package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"text/template"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
)

type PluginMeta struct {
	Name        string
	Author      string
	Description string
}

var initCmd = &cobra.Command{
	Use:   "init <name>",
	Short: "创建一个新的 JuanNiang 插件",
	Long:  "交互式创建新的 JuanNiang 插件，自动生成 pluggin.yaml、main.lua 和 jn.lua SDK。",
	Args:  cobra.ExactArgs(1),
	RunE:  runInit,
}

func runInit(cmd *cobra.Command, args []string) error {
	name := args[0]

	reader := bufio.NewReader(os.Stdin)

	fmt.Print(color.CyanString("📝 作者名 (默认: anonymous): "))
	author, _ := reader.ReadString('\n')
	author = strings.TrimSpace(author)
	if author == "" {
		author = "anonymous"
	}

	fmt.Print(color.CyanString("📝 插件简介: "))
	desc, _ := reader.ReadString('\n')
	desc = strings.TrimSpace(desc)
	if desc == "" {
		desc = "A JuanNiang plugin"
	}

	meta := PluginMeta{Name: name, Author: author, Description: desc}

	targetDir := filepath.Join(pluginsDir(), name)
	if _, err := os.Stat(targetDir); err == nil {
		return fmt.Errorf("插件目录已存在: %s", targetDir)
	}

	if err := os.MkdirAll(targetDir, 0755); err != nil {
		return fmt.Errorf("创建目录失败: %w", err)
	}

	files := []string{"pluggin.yaml", "main.lua"}
	for _, f := range files {
		tmpl, err := template.ParseFiles(filepath.Join(templateDir(), f))
		if err != nil {
			return fmt.Errorf("读取模板失败 %s: %w", f, err)
		}
		out, err := os.Create(filepath.Join(targetDir, f))
		if err != nil {
			return fmt.Errorf("创建文件失败: %w", err)
		}
		defer out.Close()
		if err := tmpl.Execute(out, meta); err != nil {
			return fmt.Errorf("渲染失败: %w", err)
		}
	}

	// 复制 SDK 文件
	sdkSrc := filepath.Join(sdkDir(), "jn.lua")
	sdkDst := filepath.Join(targetDir, "jn.lua")
	sdkData, err := os.ReadFile(sdkSrc)
	if err == nil {
		os.WriteFile(sdkDst, sdkData, 0644)
	}

	fmt.Println()
	fmt.Println(color.GreenString("✅ 插件创建成功!"))
	fmt.Printf("   📁 %s\n", color.CyanString(targetDir))
	fmt.Print("   📄 pluggin.yaml, main.lua")
	if _, err := os.Stat(sdkDst); err == nil {
		fmt.Print(", jn.lua (SDK)")
	}
	fmt.Println()
	fmt.Println()
	fmt.Printf("   放入 JuanNiang-Neo 的 %s 即可加载。\n", color.YellowString("data/pluggins/"))
	return nil
}

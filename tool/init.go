package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"text/template"
)

type PluginMeta struct {
	Name        string
	Author      string
	Description string
}

func cmdInit(args []string) {
	if len(args) < 1 {
		fmt.Println("❌ 用法: hago init <插件名>")
		os.Exit(1)
	}
	name := args[0]

	reader := bufio.NewReader(os.Stdin)

	fmt.Print("📝 作者名 (默认: anonymous): ")
	author, _ := reader.ReadString('\n')
	author = strings.TrimSpace(author)
	if author == "" {
		author = "anonymous"
	}

	fmt.Print("📝 插件简介: ")
	desc, _ := reader.ReadString('\n')
	desc = strings.TrimSpace(desc)
	if desc == "" {
		desc = "A JuanNiang plugin"
	}

	meta := PluginMeta{Name: name, Author: author, Description: desc}

	targetDir := filepath.Join(pluginsDir(), name)
	if _, err := os.Stat(targetDir); err == nil {
		fmt.Printf("❌ 插件目录已存在: %s\n", targetDir)
		os.Exit(1)
	}

	if err := os.MkdirAll(targetDir, 0755); err != nil {
		fmt.Printf("❌ 创建目录失败: %v\n", err)
		os.Exit(1)
	}

	files := []string{"pluggin.yaml", "main.lua"}
	for _, f := range files {
		tmpl, err := template.ParseFiles(filepath.Join(templateDir(), f))
		if err != nil {
			fmt.Printf("❌ 读取模板失败 %s: %v\n", f, err)
			os.Exit(1)
		}
		out, err := os.Create(filepath.Join(targetDir, f))
		if err != nil {
			fmt.Printf("❌ 创建文件失败: %v\n", err)
			os.Exit(1)
		}
		defer out.Close()
		if err := tmpl.Execute(out, meta); err != nil {
			fmt.Printf("❌ 渲染失败: %v\n", err)
			os.Exit(1)
		}
	}

	sdkSrc := filepath.Join(sdkDir(), "jn.lua")
	sdkDst := filepath.Join(targetDir, "jn.lua")
	sdkData, err := os.ReadFile(sdkSrc)
	if err == nil {
		os.WriteFile(sdkDst, sdkData, 0644)
	}

	fmt.Println()
	fmt.Printf("✅ 插件创建成功!\n")
	fmt.Printf("   📁 %s\n", targetDir)
	fmt.Printf("   📄 pluggin.yaml, main.lua")
	if _, err := os.Stat(sdkDst); err == nil {
		fmt.Printf(", jn.lua (SDK)")
	}
	fmt.Printf("\n\n   放入 JuanNiang-Neo 的 data/pluggins/ 即可加载。\n")
}

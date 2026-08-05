package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

// validateCmd 校验插件格式是否符合新规范（供 PR 审核 CI 调用）。
var validateCmd = &cobra.Command{
	Use:   "validate <name>",
	Short: "校验插件格式是否符合规范",
	Long:  "校验插件是否满足新格式 5 件套（main.lua / pluggin.yaml / config.yaml / README.md / avatar.png）并检查 config.yaml schema 合法性。",
	Args:  cobra.ExactArgs(1),
	RunE:  runValidate,
}

func init() {
	validateCmd.Flags().Bool("strict", false, "严格模式：缺失非必需元数据也报错")
}

// schema 校验：type 必须属于 bool|string|list，key 非空。
func runValidate(cmd *cobra.Command, args []string) error {
	name := args[0]
	strict, _ := cmd.Flags().GetBool("strict")
	dir := filepath.Join(pluginsDir(), name)

	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return fmt.Errorf("插件目录不存在: %s", dir)
	}

	errors := []string{}
	warnings := []string{}

	// 1. 必需文件
	for _, f := range []string{"pluggin.yaml", "main.lua"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			errors = append(errors, fmt.Sprintf("缺少必需文件 %s", f))
		}
	}
	// 2. 新格式 5 件套（弱校验）
	for _, f := range []string{"config.yaml", "README.md", "avatar.png"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			warnings = append(warnings, fmt.Sprintf("缺少 %s（建议补齐新格式 5 件套）", f))
		}
	}

	// 3. pluggin.yaml 字段
	if data, err := os.ReadFile(filepath.Join(dir, "pluggin.yaml")); err == nil {
		var m PluginManifest
		if yaml.Unmarshal(data, &m) != nil {
			errors = append(errors, "pluggin.yaml 解析失败")
		} else {
			if m.Name == "" {
				errors = append(errors, "pluggin.yaml: name 不能为空")
			}
			if m.Version == "" {
				errors = append(errors, "pluggin.yaml: version 不能为空")
			}
			if m.Version != "" && !strings.Contains(m.Version, ".") {
				warnings = append(warnings, fmt.Sprintf("version %q 建议使用 x.y.z 语义化版本", m.Version))
			}
		}
	}

	// 4. config.yaml schema 校验
	if data, err := os.ReadFile(filepath.Join(dir, "config.yaml")); err == nil {
		var cfg pluginConfigYAML
		if yaml.Unmarshal(data, &cfg) != nil {
			errors = append(errors, "config.yaml 解析失败")
		} else {
			seen := map[string]bool{}
			for _, item := range cfg.Configs {
				if item.Key == "" {
					errors = append(errors, "config.yaml: 存在缺少 key 的配置项")
					continue
				}
				if seen[item.Key] {
					errors = append(errors, fmt.Sprintf("config.yaml: 重复的 key %q", item.Key))
				}
				seen[item.Key] = true
				switch item.Type {
				case "bool", "string", "list":
					// ok
				default:
					errors = append(errors, fmt.Sprintf("config.yaml: %q 的 type %q 非法（仅支持 bool/string/list）", item.Key, item.Type))
				}
			}
		}
	}

	// 输出结果
	for _, e := range errors {
		fmt.Println(color.RedString("   ✖ %s", e))
	}
	for _, w := range warnings {
		if strict {
			errors = append(errors, w)
		}
		fmt.Println(color.YellowString("   ⚠ %s", w))
	}

	if len(errors) > 0 {
		return fmt.Errorf("校验失败：%d 个错误", len(errors))
	}
	fmt.Println(color.GreenString("✅ 校验通过: %s", name))
	return nil
}

// pluginConfigYAML 是 config.yaml 的最小校验结构（与主项目 schema 一致）。
type pluginConfigYAML struct {
	Configs []pluginConfigItemYAML `yaml:"configs"`
}

type pluginConfigItemYAML struct {
	Key  string `yaml:"key"`
	Type string `yaml:"type"`
}

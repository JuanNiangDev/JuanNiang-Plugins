package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "init":
		cmdInit(os.Args[2:])
	case "pack":
		cmdPack(os.Args[2:])
	case "scan":
		cmdScan(os.Args[2:])
	case "help", "-h", "--help":
		printUsage()
	default:
		fmt.Printf("❌ 未知命令: %s\n\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println(`╔══════════════════════════════════════════╗
║        JuanNiang Plugin Tool (hago)       ║
╠══════════════════════════════════════════╣
║                                           ║
║  init  <name>    创建新插件                ║
║  pack  <name>    打包插件为 .zip           ║
║  scan            扫描插件并更新元数据       ║
║  help            显示此帮助                ║
║                                           ║
╚══════════════════════════════════════════╝`)
}

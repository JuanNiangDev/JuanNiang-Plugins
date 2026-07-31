package main

import (
	"fmt"
	"os"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "hago",
	Short: "JuanNiang Plugin Tool",
	Long: color.CyanString(`╔══════════════════════════════════════════╗
║        JuanNiang Plugin Tool (hago)      ║
╚══════════════════════════════════════════╝`),
	SilenceUsage:  true,
	SilenceErrors: true,
}

func init() {
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(packCmd)
	rootCmd.AddCommand(scanCmd)
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, color.RedString("✖ %s", err))
		os.Exit(1)
	}
}

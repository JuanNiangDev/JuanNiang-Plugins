.PHONY: all build clean scan pack init help

BINARY   := hago
TOOL_DIR := tool
GO       := go
GOFLAGS  :=

# 默认输出目录为仓库根目录，可通过 BUILD_DIR 覆盖
BUILD_DIR ?= .

all: build

## build: 编译 hago CLI 工具
build:
	cd $(TOOL_DIR) && $(GO) build $(GOFLAGS) -o ../$(BUILD_DIR)/$(BINARY) .

## clean: 清理编译产物和打包文件
clean:
	@rm -f $(BINARY)
	@rm -f plugins/*.zip
	@echo "✅ 清理完成"

## scan: 扫描插件并更新元数据
scan: build
	./$(BINARY) scan

## pack: 打包指定插件 (用法: make pack NAME=ping)
pack: build
	@if [ -z "$(NAME)" ]; then \
		echo "❌ 请指定插件名: make pack NAME=<name>"; \
		exit 1; \
	fi
	./$(BINARY) pack $(NAME)

## init: 创建新插件 (用法: make init NAME=my-plugin)
init: build
	@if [ -z "$(NAME)" ]; then \
		echo "❌ 请指定插件名: make init NAME=<name>"; \
		exit 1; \
	fi
	./$(BINARY) init $(NAME)

## tidy: 整理 Go 依赖
tidy:
	cd $(TOOL_DIR) && $(GO) mod tidy

## help: 显示帮助
help:
	@echo "JuanNiang-Plugins Makefile"
	@echo ""
	@echo "用法: make <target> [变量]"
	@echo ""
	@grep -E '^##' Makefile | cut -c 4- | column -t -s ':'

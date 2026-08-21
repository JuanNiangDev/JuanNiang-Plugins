#!/usr/bin/env bash
# ====================================================================
# 重新生成卡片内嵌字体子集并注入 templates/card-5.html
# --------------------------------------------------------------------
# 为什么需要：T2I 渲染服务只收到 HTML 文本（无文件上传通道），
# 卡片模板必须把字体以 base64 data URI 内嵌。
#
# 依赖：fonttools + brotli（本机系统 Python 是 PEP 668 托管，建议用 venv）：
#   python3 -m venv /tmp/fontenv
#   /tmp/fontenv/bin/pip install fonttools brotli
#
# 用法（在插件目录或本脚本所在目录执行）：
#   PYFTSUBSET=/tmp/fontenv/bin/pyftsubset ./fonts/rebuild.sh
# ====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

TTF=MapleMonoNormal-NF-CN-Regular.ttf
CHARSET=fonts/charset.txt
WOFF2=fonts/card-best.woff2
TEMPLATE=templates/card-5.html
PYFTSUBSET="${PYFTSUBSET:-pyftsubset}"

if [[ ! -f "$TTF" ]]; then
    echo "错误：找不到 $TTF（原始字体）" >&2
    exit 1
fi

# 1) 子集化：ASCII + Latin-1 + 常用标点符号 + GB2312 一级汉字（3755 个）
"$PYFTSUBSET" "$TTF" \
    --flavor=woff2 \
    --output-file="$WOFF2" \
    --text-file="$CHARSET" \
    --layout-features='*'

# 2) 把新 base64 注入模板 <style> 里的 @font-face src 行
python3 - "$WOFF2" "$TEMPLATE" <<'PYEOF'
import base64, sys

woff2, tmpl = sys.argv[1], sys.argv[2]
b64 = base64.b64encode(open(woff2, "rb").read()).decode()
new_src = f'src: url(data:font/woff2;base64,{b64}) format("woff2");'

lines = open(tmpl, encoding="utf-8").read().split("\n")
hits = 0
for i, line in enumerate(lines):
    if 'url(data:font/woff2;base64,' in line and 'format("woff2")' in line:
        lines[i] = "  " + new_src
        hits += 1
if hits != 1:
    raise SystemExit(f"错误：模板中匹配到 {hits} 处字体 src，应为 1 处")
open(tmpl, "w", encoding="utf-8").write("\n".join(lines))
print(f"OK：已注入 {len(b64)} 字符 base64 到 {tmpl}")
PYEOF

echo "完成：$(ls -lh "$WOFF2" | awk '{print $5}')"

#!/usr/bin/env python3
"""插件头像确定性校验脚本。

校验透明背景 + 不透明主体 + 边缘抗锯齿容差，输出可重复的数值与 PASS/FAIL，
避免不同审核者凭肉眼得出不一致结论。

阈值（可在下方常量调整）：
  TRANSPARENT_MIN_RATIO = 0.05  # alpha=0 像素占比下限（证明有透明背景）
  OPAQUE_MIN_RATIO     = 0.05  # alpha>=250 像素占比下限（证明有实体主体）
  SEMI_MAX_RATIO       = 0.30  # 明显半透明像素(0<alpha<250)占比上限（抗锯齿/高光边缘容差；含 250-255 的近不透明柔边不计入）
"""
import sys

import numpy as np
from PIL import Image

TRANSPARENT_MIN_RATIO = 0.05
OPAQUE_MIN_RATIO = 0.05
SEMI_MAX_RATIO = 0.30


def validate(path: str) -> int:
    """校验头像 PNG 的透明背景与不透明主体占比。

    图片不可读（缺失 / 损坏 / 非图片格式）会触发 Pillow 的 OSError，
    捕获后判为验证失败；其余异常视为校验器缺陷，向上传播。
    返回 0 表示通过，1 表示不通过。
    """
    try:
        with Image.open(path, formats=["PNG"]) as im:
            a = np.array(im.convert("RGBA").getchannel("A")).astype(int)
    except OSError as e:  # 文件缺失 / 损坏 / 非 PNG 格式 → 判为验证失败
        print("file: %s" % path)
        print("  [FAIL] readable PNG -> %s" % e)
        print("RESULT: FAIL")
        return 1
    total = a.size
    transparent = int((a == 0).sum())
    opaque = int((a >= 250).sum())
    semi = int(((a > 0) & (a < 250)).sum())  # 明显半透明；排除 250-255 的近不透明抗锯齿/柔边内侧
    tr = transparent / total
    or_ = opaque / total
    sr = semi / total

    checks = [
        (
            "transparent background (alpha=0 >= %.0f%%)" % (TRANSPARENT_MIN_RATIO * 100),
            tr >= TRANSPARENT_MIN_RATIO,
            "%.1f%%" % (tr * 100),
        ),
        (
            "opaque subject (alpha>=250 >= %.0f%%)" % (OPAQUE_MIN_RATIO * 100),
            or_ >= OPAQUE_MIN_RATIO,
            "%.1f%%" % (or_ * 100),
        ),
        (
            "edge antialias within tolerance (semi <= %.0f%%)" % (SEMI_MAX_RATIO * 100),
            sr <= SEMI_MAX_RATIO,
            "%.1f%%" % (sr * 100),
        ),
    ]

    ok = all(c[1] for c in checks)
    print("file: %s" % path)
    for name, passed, val in checks:
        print("  [%s] %s -> %s" % ("PASS" if passed else "FAIL", name, val))
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: python3 docs/avatar-validate.py <path-to-avatar.png>")
        sys.exit(2)
    sys.exit(validate(sys.argv[1]))

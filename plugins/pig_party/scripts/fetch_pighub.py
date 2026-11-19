#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取 PigHub 猪猪表情库，导入卷娘 Neo 图床（或下载到本地目录）。

数据源：https://pighub.top/api/images?sort=2
  返回 {"code":0,"data":[{"id":1361,"title":"你知道吗","filename":"你知道吗.jpg",
        "image_url":"/images/你知道吗.jpg"}, ...]}

用法示例
--------
# 1) 先看有哪些图（不下载）
python3 fetch_pighub.py --dry-run --limit 20

# 2) 下载到本地目录（自行挑图后手动上传）
python3 fetch_pighub.py --output-dir ./pig_images --limit 100

# 3) 直接导入卷娘图床（自动建目录 + 跳过已存在）
python3 fetch_pighub.py --neo-url http://127.0.0.1:8090 \
    --username admin --password 'Admin123' \
    --folder pig_party --limit 200 --skip-existing

# 4) 已有 JWT 时免登录
python3 fetch_pighub.py --neo-url https://bot.example.com --token 'eyJhbGci...' --folder pig_party

依赖：仅标准库（urllib）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PIGHUB_SITE = "https://pighub.top"
PIGHUB_API = f"{PIGHUB_SITE}/api/images?sort=2"

# 图床上传限制（与后端 maxImageSize / MIME 白名单一致）
MAX_UPLOAD_BYTES = 1536 * 1024  # 1.5MB
ALLOWED_SUFFIX = {".jpg", ".jpeg", ".png", ".gif", ".webp"}
USER_AGENT = "juan-niang-pig-party-importer/1.0"


def http_request(url, method="GET", data=None, headers=None, timeout=30):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", USER_AGENT)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def fetch_pighub_list(timeout=30):
    """拉取 PigHub 图片索引，返回 [{id,title,filename,url}]。"""
    status, body = http_request(PIGHUB_API, timeout=timeout)
    if status != 200:
        raise RuntimeError(f"PigHub 接口返回 HTTP {status}")
    payload = json.loads(body.decode("utf-8"))
    items = payload.get("data") or []
    out = []
    for it in items:
        if not isinstance(it, dict):
            continue
        rel = str(it.get("image_url") or "").strip()
        if not rel:
            filename = str(it.get("filename") or "").strip()
            rel = f"/images/{filename}" if filename else ""
        if not rel:
            continue
        url = urllib.parse.urljoin(PIGHUB_SITE, rel)
        title = str(it.get("title") or "").strip()
        filename = str(it.get("filename") or "").strip() or Path(urllib.parse.urlsplit(url).path).name
        if not title:
            title = Path(filename).stem or str(it.get("id") or "未命名")
        out.append({
            "id": it.get("id"),
            "title": title,
            "filename": filename,
            "url": url,
        })
    return out


def download(url, timeout=60):
    status, body = http_request(url, timeout=timeout)
    if status != 200:
        raise RuntimeError(f"HTTP {status}")
    return body


# ---------------------------------------------------------------------------
# 卷娘 Neo 图床
# ---------------------------------------------------------------------------

class NeoClient:
    def __init__(self, base_url, token=None):
        self.base = base_url.rstrip("/")
        self.token = token

    def _headers(self, json_body=False):
        h = {}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        if json_body:
            h["Content-Type"] = "application/json"
        return h

    def login(self, username, password):
        payload = json.dumps({"username": username, "password": password}).encode()
        status, body = http_request(
            f"{self.base}/api/v1/login", method="POST", data=payload,
            headers={"Content-Type": "application/json"})
        data = json.loads(body.decode("utf-8"))
        if data.get("status") != 0:
            raise RuntimeError(f"登录失败: {data.get('info')}")
        self.token = data["data"]["token"]
        return self.token

    def ensure_folder(self, folder):
        """确保图床虚拟目录存在（不存在则创建）。"""
        status, body = http_request(
            f"{self.base}/api/v1/image-folders", headers=self._headers())
        data = json.loads(body.decode("utf-8"))
        if data.get("status") != 0:
            raise RuntimeError(f"读取图床目录失败: {data.get('info')}")
        names = {f.get("name") for f in (data.get("data") or [])}
        if folder in names:
            return False
        payload = json.dumps({"name": folder}).encode()
        status, body = http_request(
            f"{self.base}/api/v1/image-folders", method="POST", data=payload,
            headers=self._headers(json_body=True))
        data = json.loads(body.decode("utf-8"))
        # 40037 = 文件夹已存在（并发场景），视为成功
        if data.get("status") not in (0, 40037):
            raise RuntimeError(f"创建图床目录失败: {data.get('info')}")
        return True

    def existing_names(self, folder):
        """分页读取指定目录下已有图片名，用于 --skip-existing。"""
        names = set()
        page = 1
        while True:
            qs = urllib.parse.urlencode({"folder": folder, "page": page, "page_size": 100})
            status, body = http_request(
                f"{self.base}/api/v1/images?{qs}", headers=self._headers())
            data = json.loads(body.decode("utf-8"))
            if data.get("status") != 0:
                raise RuntimeError(f"读取图床图片失败: {data.get('info')}")
            payload = data.get("data") or {}
            items = payload.get("list") or []
            for it in items:
                if it.get("name"):
                    names.add(str(it["name"]))
            total = int(payload.get("total") or 0)
            if page * 100 >= total or not items:
                break
            page += 1
        return names

    def upload(self, filename, content, name, folder):
        boundary = "----juanNiangPigPartyBoundary"
        parts = []
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode("utf-8"))
        parts.append(b"Content-Type: application/octet-stream\r\n\r\n")
        parts.append(content)
        parts.append(b"\r\n")
        for field, value in (("name", name), ("folder", folder)):
            parts.append(f"--{boundary}\r\n".encode())
            parts.append(
                f'Content-Disposition: form-data; name="{field}"\r\n\r\n'.encode("utf-8"))
            parts.append(str(value).encode("utf-8"))
            parts.append(b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)
        headers = self._headers()
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        status, resp = http_request(
            f"{self.base}/api/v1/images", method="POST", data=body, headers=headers)
        data = json.loads(resp.decode("utf-8"))
        if data.get("status") != 0:
            raise RuntimeError(f"{data.get('info')} {data.get('data') or ''}".strip())
        return data.get("data")


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="抓取 PigHub 猪图并导入卷娘图床（或下载到本地）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=0, help="最多处理多少张（0=全部）")
    ap.add_argument("--skip", type=int, default=0, help="跳过前 N 张（断点续传用）")
    ap.add_argument("--dry-run", action="store_true", help="只列出将要处理的图片，不下载/上传")
    ap.add_argument("--output-dir", help="下载到该目录（与 --neo-url 二选一）")
    ap.add_argument("--neo-url", help="卷娘 Neo 地址，如 http://127.0.0.1:8090")
    ap.add_argument("--username", default="admin", help="Neo 登录用户名（默认 admin）")
    ap.add_argument("--password", help="Neo 登录密码")
    ap.add_argument("--token", help="已有 JWT（提供后免登录）")
    ap.add_argument("--folder", default="pig_party", help="目标图床目录名（默认 pig_party，自动创建）")
    ap.add_argument("--skip-existing", action="store_true", help="跳过图床中已存在的同名图片")
    ap.add_argument("--max-bytes", type=int, default=MAX_UPLOAD_BYTES,
                    help=f"超过该大小的图片跳过（默认 {MAX_UPLOAD_BYTES} 字节，图床上限 1.5MB）")
    ap.add_argument("--timeout", type=int, default=60, help="单次网络超时秒数（默认 60）")
    ap.add_argument("--retry", type=int, default=2, help="单张失败重试次数（默认 2）")
    args = ap.parse_args()

    if not args.dry_run and not args.output_dir and not args.neo_url:
        ap.error("需要指定 --output-dir 或 --neo-url（或用 --dry-run 预览）")

    print(f"拉取 PigHub 索引: {PIGHUB_API}")
    pigs = fetch_pighub_list(timeout=args.timeout)
    print(f"共 {len(pigs)} 张")
    if args.skip:
        pigs = pigs[args.skip:]
    if args.limit > 0:
        pigs = pigs[:args.limit]
    print(f"本次处理 {len(pigs)} 张")

    if args.dry_run:
        for i, p in enumerate(pigs, 1):
            print(f"  {i:>4}. {p['title']}  <-  {p['url']}")
        return 0

    client = None
    existing = set()
    out_dir = None
    if args.neo_url:
        client = NeoClient(args.neo_url, args.token)
        if not client.token:
            if not args.password:
                ap.error("未提供 --token 时必须提供 --password")
            client.login(args.username, args.password)
            print("登录成功")
        if client.ensure_folder(args.folder):
            print(f"已创建图床目录 /{args.folder}")
        if args.skip_existing:
            existing = client.existing_names(args.folder)
            print(f"图床 /{args.folder} 现有 {len(existing)} 张")
    else:
        out_dir = Path(args.output_dir).expanduser()
        out_dir.mkdir(parents=True, exist_ok=True)
        print(f"下载目录: {out_dir}")

    ok = skipped = failed = 0
    for i, p in enumerate(pigs, 1):
        name = p["title"]
        if args.skip_existing and name in existing:
            skipped += 1
            print(f"[{i}/{len(pigs)}] 跳过（已存在）: {name}")
            continue

        suffix = Path(p["filename"]).suffix.lower() or ".jpg"
        if suffix not in ALLOWED_SUFFIX:
            skipped += 1
            print(f"[{i}/{len(pigs)}] 跳过（不支持的格式 {suffix}）: {name}")
            continue

        content = None
        last_err = None
        for attempt in range(args.retry + 1):
            try:
                content = download(p["url"], timeout=args.timeout)
                break
            except Exception as exc:  # noqa: BLE001
                last_err = exc
                time.sleep(1.0 + attempt)
        if content is None:
            failed += 1
            print(f"[{i}/{len(pigs)}] 下载失败: {name} ({last_err})")
            continue
        if len(content) > args.max_bytes:
            skipped += 1
            print(f"[{i}/{len(pigs)}] 跳过（{len(content)/1024:.0f}KB 超过上限）: {name}")
            continue

        try:
            if client is not None:
                client.upload(p["filename"], content, name, args.folder)
            else:
                target = out_dir / p["filename"]
                target.write_bytes(content)
            ok += 1
            print(f"[{i}/{len(pigs)}] 完成: {name} ({len(content)/1024:.0f}KB)")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"[{i}/{len(pigs)}] 失败: {name} ({exc})")

    print(f"\n完成：成功 {ok} / 跳过 {skipped} / 失败 {failed}")
    if client is not None:
        print(f"图床目录：/{args.folder}（插件配置 image_bed_folders 填 \"{args.folder}\" 即可生效）")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

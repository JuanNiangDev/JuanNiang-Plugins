#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
modeldb-rebuild.py — repo-intro 模型信息收集链路
=================================================
从 4 个来源收集模型信息（上下文/参数量/输入类型/定价），按共享别名
union-find 归并成规范条目，生成紧凑 modeldb.json 供插件卡片渲染：

  1. llmrates.ai  /zh-Hans/models  (Next.js flight data)
       contextWindow / maxOutput / modalities / provider(nameLocal)
       price + prices[]：CNY+USD × standard/off_peak × token 分段
  2. models.dev   /api.json        兜底：context/modalities/cost(USD)
  3. newapiratio  /api.json        交叉校验/兜底
  4. openrouter   /api/v1/models    hugging_face_id 映射 + 描述里的参数量

用法:
  python3 modeldb-rebuild.py            # 拉取全部并写 modeldb.json
  python3 modeldb-rebuild.py --offline  # 只用本地缓存重生成
"""
import json, os, re, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "modeldb.json")
CACHE = os.path.join(HERE, ".modeldb-cache")
os.makedirs(CACHE, exist_ok=True)
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36"}

def fetch(url, cache_name=None, timeout=60):
    cp = os.path.join(CACHE, cache_name or re.sub(r'[^a-z0-9]', '_', url.split('//')[1]) + '.bin')
    if os.path.exists(cp) and os.path.getmtime(cp) > time.time() - 86400 * 7:
        return open(cp, 'rb').read()
    if '--offline' in sys.argv:
        return open(cp, 'rb').read() if os.path.exists(cp) else b''
    req = urllib.request.Request(url, headers=UA)
    data = urllib.request.urlopen(req, timeout=timeout).read()
    open(cp, 'wb').write(data)
    return data

# ---------------- 1. llmrates ----------------
def parse_flight(html):
    chunks = re.findall(r'self\.__next_f\.push\(\[(\d+),("(?:\\.|[^"\\])*")\]\)', html)
    parts = []
    for n, s in chunks:
        try:
            parts.append((int(n), json.loads(s)))
        except Exception:
            pass
    parts.sort(key=lambda x: x[0])
    return ''.join(p for _, p in parts)

def json_brace_end(s, start):
    depth, i, in_str = 0, start, False
    while i < len(s):
        c = s[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    return None

def collect_llmrates():
    html = fetch("https://www.llmrates.ai/zh-Hans/models", "llmrates.html", 90).decode('utf-8', 'replace')
    payload = parse_flight(html)
    i = payload.find('{"models":[')
    if i < 0:
        print("llmrates: no models array")
        return {}
    end = json_brace_end(payload, i)
    models = json.loads(payload[i:end])['models']
    print("llmrates models:", len(models))
    out = {}
    for m in models:
        slug = (m.get('slug') or '').strip().lower()
        if not slug:
            continue
        prov = m.get('provider') or {}
        name = m.get('name') or ''
        price = m.get('price') or {}
        prices = m.get('prices') or []
        aliases = {slug, (prov.get('slug') or '').strip().lower() + '/' + slug}
        if name:
            aliases.add(name.lower())
        rec = {
            "name": name, "provider": prov.get('name'), "provider_local": prov.get('nameLocal'),
            "cn": bool(prov.get('nameLocal')),
            "context": m.get('contextWindow'), "max_output": m.get('maxOutput'),
            "modalities": m.get('modalities') or [],
            "supports_caching": bool(m.get('supportsCaching')),
            "supports_tools": bool(m.get('supportsTools')),
            "pricing": [],
            "aliases": aliases,
        }
        for p in prices:
            rec["pricing"].append({
                "cur": p.get("priceUnit"), "tier": p.get("processingTier") or p.get("tierLabel") or "standard",
                "input": p.get("inputPricePerMillion"), "output": p.get("outputPricePerMillion"),
                "thinking": p.get("thinkingOutputPricePerMillion"), "cache": p.get("cachedInputPricePerMillion"),
                "min": p.get("tokenTierMin"), "max": p.get("tokenTierMax"),
            })
        if not rec["pricing"] and price:
            rec["pricing"].append({
                "cur": price.get("priceUnit"), "tier": "standard",
                "input": price.get("inputPricePerMillion"), "output": price.get("outputPricePerMillion"),
                "thinking": price.get("thinkingOutputPricePerMillion"), "cache": price.get("cachedInputPricePerMillion"),
                "min": None, "max": None,
            })
        out[slug] = rec
    return out

# ---------------- 2/3. models.dev / newapiratio ----------------
def collect_catalog(url, cache_name):
    resp = fetch(url, cache_name, 60)
    if not resp:
        print(f"!! {url.split('/')[2]} 空响应，跳过该来源")
        return {}
    data = json.loads(resp.decode('utf-8', 'replace'))
    out = {}
    for pid, p in data.items():
        for mid, m in (p.get('models') or {}).items():
            cost = m.get('cost') or {}
            mods = (m.get('modalities') or {}).get('input') or []
            out.setdefault(mid.strip().lower(), {
                "name": None, "provider": p.get('name'), "provider_local": None, "cn": None,
                "context": (m.get('limit') or {}).get('context'), "max_output": (m.get('limit') or {}).get('output'),
                "modalities": mods, "supports_caching": None, "supports_tools": bool(m.get('tool_call')),
                "pricing": [], "aliases": {mid.strip().lower()},
                "cost": {"input": cost.get('input'), "output": cost.get('output'), "cache": cost.get('cache_read')},
                "reasoning": bool(m.get('reasoning')),
            })
    print(f"{url.split('/')[2]} models:", len(out))
    return out

# ---------------- 4. openrouter ----------------
def collect_openrouter():
    resp = fetch("https://openrouter.ai/api/v1/models", "openrouter.json", 60)
    if not resp:
        print("!! openrouter 空响应，跳过该来源")
        return {}
    data = json.loads(resp.decode('utf-8', 'replace'))
    items = data.get('data', [])
    print("openrouter models:", len(items))
    out = {}
    for m in items:
        arch = m.get('architecture') or {}
        mods = arch.get('input_modalities') or []
        desc = m.get('description') or ''
        params = extract_params((m.get('id') or '') + ' ' + (m.get('name') or '') + ' ' + desc)
        hid = m.get('hugging_face_id')
        aliases = {(m.get('id') or '').strip().lower()}
        if hid:
            aliases.add(hid.lower())
        out.setdefault(m.get('id', '').strip().lower(), {
            "name": m.get('name'), "provider": None, "provider_local": None, "cn": None,
            "context": m.get('context_length'), "max_output": None,
            "modalities": mods, "supports_caching": None, "supports_tools": None,
            "pricing": [], "aliases": aliases, "params": params,
            "cost": {"input": (m.get('pricing', {}) or {}).get('prompt'),
                     "output": (m.get('pricing', {}) or {}).get('completion'),
                     "cache": (m.get('pricing', {}) or {}).get('input_cache_read')},
            "reasoning": None,
        })
    return out

# ---------------- 参数量提取 ----------------
def extract_params(text):
    s = (text or '').lower()
    m = re.search(r'(\d+(?:\.\d+)?)\s*b\s*out of\s*(\d+(?:\.\d+)?)\s*b', s)
    if m:
        return f"{m.group(2)}B"
    m = re.search(r'(\d+(?:\.\d+)?)\s*b\s*parameters', s)
    if m:
        return f"{m.group(1)}B"
    # 名字里的参数量：数字后紧跟 b/t 且前面不是单词/点（避免 v3.1、k2-5 误报）
    m = re.search(r'(?<![\w.])(\d+(?:\.\d+)?)\s*(t|b)\b', s)
    if m and float(m.group(1)) < 3000:
        return f"{m.group(1)}{m.group(2).upper()}"
    return None

# ---------------- 归一化合并（union-find） ----------------
def norm_key(s):
    return re.sub(r'[^a-z0-9]', '', (s or '').lower())

def build_db(llm, mdev, napi, ortr):
    raw = []
    for src, label in ((llm, 'llmrates'), (mdev, 'models.dev'), (napi, 'newapiratio'), (ortr, 'openrouter')):
        for k, v in src.items():
            raw.append(dict(v, aliases=set(v.get('aliases', [k])), src=label))

    parent = list(range(len(raw)))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    alias_owner = {}
    for i, r in enumerate(raw):
        extra = set()
        for a in r['aliases']:
            na = norm_key(a)
            if na in alias_owner:
                union(alias_owner[na], i)
            else:
                alias_owner[na] = i
            # 含 owner/name 形式的别名：额外索引"纯名"部分，把 owner/name 与 name 关联
            # （qwen/qwen2.5-7b-instruct 与 llmrates 的 qwen2-5-7b-instruct 同模型）
            if '/' in a:
                nm = norm_key(a.rsplit('/', 1)[1])
                if nm and nm != na:
                    extra.add(nm)
        for nm in extra:
            if nm in alias_owner:
                union(alias_owner[nm], i)
            else:
                alias_owner[nm] = i

    groups = {}
    for i in range(len(raw)):
        groups.setdefault(find(i), []).append(i)

    canonical = {}
    alias_idx = {}
    for gid, idxs in groups.items():
        rec = {"aliases": set(), "pricing": [], "modalities": [], "sources": set(),
               "name": None, "provider": None, "provider_local": None, "cn": None,
               "context": None, "max_output": None, "params": None,
               "supports_caching": None, "supports_tools": None, "reasoning": None, "cost": None}
        for i in idxs:
            r = raw[i]
            rec["sources"].add(r.get('src'))
            rec["aliases"] |= r['aliases']
            if r.get('name') and rec["name"] is None:
                rec["name"] = r['name']
            if r.get('provider') and (rec["provider"] is None or r.get('src') == 'llmrates'):
                rec["provider"] = r['provider']
            if r.get('provider_local') is not None and (rec["provider_local"] is None or r.get('src') == 'llmrates'):
                rec["provider_local"] = r['provider_local']
            if r.get('cn') is not None and (rec["cn"] is None or r.get('src') == 'llmrates'):
                rec["cn"] = r['cn']
            if r.get('context') and rec["context"] is None:
                rec["context"] = r['context']
            if r.get('max_output') and rec["max_output"] is None:
                rec["max_output"] = r['max_output']
            if r.get('params') and rec["params"] is None:
                rec["params"] = r['params']
            if r.get('modalities'):
                rec["modalities"] = list(dict.fromkeys(rec["modalities"] + r['modalities']))
            if r.get('supports_caching') is not None and rec["supports_caching"] is None:
                rec["supports_caching"] = r['supports_caching']
            if r.get('supports_tools') is not None and rec["supports_tools"] is None:
                rec["supports_tools"] = r['supports_tools']
            if r.get('reasoning') is not None and rec["reasoning"] is None:
                rec["reasoning"] = r['reasoning']
            if r.get('pricing'):
                # 累计所有来源的定价档，卡片侧按币种/时段挑选（不取第一个）
                rec["pricing"] = rec["pricing"] + [p for p in r['pricing'] if p not in rec["pricing"]]
            if r.get('cost') and rec["cost"] is None:
                rec["cost"] = r['cost']
        pref = sorted(rec["aliases"], key=lambda a: (0 if '/' in a else 1, -len(a)))
        main = norm_key(pref[0]) or ('m%d' % gid)
        canonical[main] = rec
        var = set()
        for a in rec["aliases"]:
            alias_idx[norm_key(a)] = main
            # 变体别名：去 owner、去常见后缀，提升 HF id 命中率
            part = a.rsplit('/', 1)[-1] if '/' in a else a
            for s in ('-instruct', '-chat', '-base', '-it', '_instruct'):
                if part.endswith(s):
                    part = part[: -len(s)]
            if part != a:
                var.add(part)
        for v in var:
            nk = norm_key(v)
            if nk not in alias_idx:  # 不覆盖其他模型已注册的精确别名
                alias_idx[nk] = main
    return canonical, alias_idx

def emit(canonical, alias_idx):
    out = {"meta": {"sources": ["llmrates", "models.dev", "newapiratio", "openrouter"],
                    "generated": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())},
           "models": {}, "alias": alias_idx}
    for nk, rec in canonical.items():
        aliases = sorted({a for a in rec['aliases'] if a})[:8]
        out["models"][nk] = {
            "n": rec.get('name') or (aliases[0] if aliases else nk),
            "p": rec.get('provider'), "pl": rec.get('provider_local'),
            "cn": bool(rec.get('cn')),
            "ctx": rec.get('context'), "mo": rec.get('max_output'),
            "md": rec.get('modalities') or [],
            "params": rec.get('params'),
            "sc": rec.get('supports_caching'), "st": rec.get('supports_tools'),
            "rs": rec.get('reasoning'),
            "cost": rec.get('cost'),
            "pr": rec.get('pricing') or [],
            "al": aliases,
        }
    print("canonical models:", len(out["models"]), "alias idx:", len(out["alias"]))
    json.dump(out, open(OUT, 'w'), ensure_ascii=False, separators=(',', ':'))
    print("written:", OUT, os.path.getsize(OUT), "bytes")

def main():
    print("== llmrates =="); llm = collect_llmrates()
    print("== models.dev =="); mdev = collect_catalog("https://models.dev/api.json", "modelsdev.json")
    print("== newapiratio =="); napi = collect_catalog("https://newapiratio.com/api.json", "newapi.json")
    print("== openrouter =="); ortr = collect_openrouter()
    canonical, alias_idx = build_db(llm, mdev, napi, ortr)
    emit(canonical, alias_idx)

if __name__ == '__main__':
    main()

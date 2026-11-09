#!/usr/bin/env python3
"""校验 API2Human 面试者角色卡（.a2hcard v1）。

用法：
    python3 validate_a2hcard.py 张三.a2hcard          # 人类可读的报告
    python3 validate_a2hcard.py 张三.a2hcard --json   # 机器可读
    python3 validate_a2hcard.py 张三.a2hcard --ai-view  # 预览面试 AI 实际看到的内容

退出码：0 = 通过（可能有警告）；1 = 有错误；2 = 文件读不了。
只用标准库，不需要安装依赖。
"""
import json
import re
import sys

SUPPORTED_VERSION = 1

# id: (中文名, 英文名, 是否必需)
SECTIONS = {
    "pitch": ("一句话定位", "Pitch", True),
    "profile": ("基本信息", "Profile", False),
    "experience": ("工作经历", "Experience", True),
    "projects": ("项目经历", "Projects", True),
    "skills": ("技能边界", "Skills", True),
    "stories": ("故事库", "Stories", False),
    "talking_points": ("求职口径", "Talking Points", False),
    "red_lines": ("红线", "Red Lines", False),
    "target": ("目标岗位", "Target Role", False),
    "voice": ("表达风格", "Voice", False),
}
REQUIRED_META = ("a2hcard", "name", "role")
RECOMMENDED_META = ("years", "language", "updated")
PROJECT_FIELDS = ("背景", "我的角色", "做法", "结果", "技术栈", "难点", "追问准备")
# 看起来像模型自己编的占位符（应改用 [待补充]）
FAKE_PLACEHOLDER = re.compile(r"XXX|xxx|\[项目名\]|\[公司名\]|\[X\]|某某")


def match_section(title):
    t = title.strip()
    for sid, (zh, en, _) in SECTIONS.items():
        if t == zh or t.lower() == en.lower():
            return sid
    return None


def parse(text):
    text = text.lstrip("﻿").replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    meta, body_start = {}, 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                body_start = i + 1
                break
            if ":" in lines[i]:
                k, v = lines[i].split(":", 1)
                meta[k.strip()] = v.strip()
        else:
            return None, {}, [], "头部元信息没有结束的 ---"
    else:
        return None, {}, [], "第一行必须是 ---（头部元信息）"

    sections, unknown, current = {}, [], "pitch"
    buf = []

    def flush():
        if current is not None:
            prev = sections.get(current, "")
            sections[current] = (prev + "\n" + "\n".join(buf)).strip()

    # 先去注释再切章节（和 App 一致）：注释里的 "## 旧项目" 不算章节
    for line in strip_comments("\n".join(lines[body_start:])).split("\n"):
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m and not line.startswith("###"):
            flush()
            buf = []
            sid = match_section(m.group(1))
            if sid is None:
                unknown.append(m.group(1))
                current = "unknown:" + m.group(1)
            else:
                current = sid
            continue
        buf.append(line)
    flush()
    return meta, sections, unknown, None


def strip_comments(s):
    return re.sub(r"<!--.*?-->", "", s, flags=re.S)


UNCONFIRMED = re.compile(r"\[待确认[^\]]*\]")
MARKER = re.compile(r"\[(待确认|待补充)[^\]]*\]")
# 行首前缀："- 字段：" / "- " / "S："——不算分句内容
LINE_PREFIX = re.compile(r"^(\s*(?:[-*]\s+)?(?:[^：:\n\[\]]{1,12}[：:])?\s*)")
DELIMS = "，,、；;。"
TRIM = DELIMS + " \t"
OPEN, CLOSE = "（(「【[", "）)」】]"


def split_clauses(s):
    """按 ，,、；;。 切分句，括号里的标点不算。分隔符留在前一个分句末尾。"""
    out, buf, depth = [], "", 0
    for ch in s:
        buf += ch
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            depth = max(0, depth - 1)
        elif ch in DELIMS and depth == 0:
            out.append(buf)
            buf = ""
    if buf:
        out.append(buf)
    return out


def ai_line(line):
    """按规范第 3 节过滤一行。返回 None 表示整行删除。"""
    if not MARKER.search(line):
        return line
    if line.lstrip().startswith("#"):          # 标题只去标记，保留结构
        return MARKER.sub("", line).rstrip()
    prefix = LINE_PREFIX.match(line).group(1)
    rest = line[len(prefix):]
    kept = [c for c in split_clauses(rest) if not MARKER.search(c)]
    content = "".join(kept).strip(TRIM)
    return prefix + content if content else None


def dangling_list_items(line):
    """顿号列表里只有后面几项带标记时，前面的项会变成残句（如"分片键、迁移方案 [待补充]"留下"分片键"）。"""
    if line.lstrip().startswith("#") or not MARKER.search(line):
        return False
    prefix = LINE_PREFIX.match(line).group(1)
    clauses = split_clauses(line[len(prefix):])
    for a, b in zip(clauses, clauses[1:]):
        if a.endswith("、") and not MARKER.search(a) and MARKER.search(b):
            return True
    return False


def ai_view(text):
    """面试 AI 实际看到的角色卡内容（规范第 4 节第 6 条）。"""
    text = strip_comments(text.lstrip("\ufeff").replace("\r\n", "\n"))
    out, in_meta, meta_done = [], False, False
    for i, line in enumerate(text.split("\n")):
        if line.strip() == "---" and not meta_done:
            in_meta = not in_meta
            meta_done = not in_meta
            out.append(line)
            continue
        if in_meta:
            if "[待确认" in line or "[待补充" in line:
                continue
            out.append(line)
            continue
        new = ai_line(line)
        if new is not None:
            out.append(new)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip() + "\n"


def validate(text):
    errors, warnings, info = [], [], []
    meta, sections, unknown, fatal = parse(text)
    if fatal:
        return {"errors": [fatal], "warnings": [], "info": [], "stats": {}}

    # 元信息
    for k in REQUIRED_META:
        if not meta.get(k):
            errors.append(f"头部缺少必需字段 {k}")
    ver = meta.get("a2hcard", "")
    if ver and not ver.isdigit():
        errors.append(f"a2hcard 版本号必须是正整数，现在是 {ver!r}")
    elif ver and int(ver) > SUPPORTED_VERSION:
        warnings.append(f"版本 {ver} 比校验器支持的 {SUPPORTED_VERSION} 新，部分规则可能不适用")
    for k in RECOMMENDED_META:
        if not meta.get(k):
            warnings.append(f"建议在头部填写 {k}")
    if "YYYY" in text:
        errors.append("还有模板里的日期占位（YYYY-MM-DD / YYYY.MM），请替换成真实日期或 [待补充]")
    if meta.get("updated") and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", meta["updated"]):
        warnings.append("updated 应为 YYYY-MM-DD")
    if meta.get("language") and meta["language"] not in ("zh", "en", "zh+en"):
        warnings.append("language 应为 zh / en / zh+en")

    # 章节
    for sid, (zh, en, required) in SECTIONS.items():
        content = strip_comments(sections.get(sid, "")).strip()
        if required and not content:
            errors.append(f"缺少必需章节「{zh}」（## {zh} 或 ## {en}）")
    for u in unknown:
        info.append(f"未知章节「{u}」会原样保留")

    pitch = strip_comments(sections.get("pitch", "")).strip()
    if len(pitch) > 200:
        warnings.append(f"一句话定位有 {len(pitch)} 字，建议 100 字以内（它是自我介绍的开头）")

    # 项目：每个 ### 检查关键字段
    projects = re.split(r"^###\s+", sections.get("projects", ""), flags=re.M)[1:]
    if sections.get("projects") and not projects:
        warnings.append("项目经历里没有 ### 项目名 小节")
    for p in projects:
        name = p.split("\n", 1)[0].strip()
        fields = set(re.findall(r"^-\s*([^：:\n]+)[：:]", p, flags=re.M))
        for must in ("我的角色", "结果"):
            if must not in fields:
                warnings.append(f"项目「{name}」缺少「{must}」字段")
        if "追问准备" not in fields:
            info.append(f"项目「{name}」可以补充「追问准备」")

    # 技能必须分档
    skills = sections.get("skills", "")
    tiers = {t: bool(re.search(rf"^-\s*{t}\s*[：:]", skills, flags=re.M)) for t in ("熟练", "用过")}
    has_boundary = bool(re.search(r"^-\s*(了解或没用过|了解|没用过)\s*[：:]", skills, flags=re.M))
    if skills and not all(tiers.values()):
        warnings.append("技能边界应分档写：- 熟练：… / - 用过：… / - 了解或没用过：…")
    if skills and not has_boundary:
        warnings.append("技能边界缺少「了解或没用过」档——它能防止面试 AI 夸大你的能力")

    # 面试 AI 视角的检查
    for line in strip_comments(text).split("\n"):
        if dangling_list_items(line):
            warnings.append(f"这一行在面试时会留下残句，请把带标记的内容拆成单独的分句：{line.strip()[:60]}")
    for tier in ("熟练", "用过"):
        tier_lines = re.findall(rf"^-\s*{tier}\s*[：:].*$", skills, flags=re.M)
        if tier_lines and all(ai_line(l) is None for l in tier_lines):
            warnings.append(f"「{tier}」档在面试时会被整档过滤（每项都带标记）——技能分档不应加 [待确认]，请把确认放进提问清单")

    # 真实性标记
    body = strip_comments(text)
    unconfirmed = len(UNCONFIRMED.findall(body))
    missing = len(re.findall(r"\[待补充[^\]]*\]", body))
    fake = FAKE_PLACEHOLDER.findall(body)
    if unconfirmed:
        warnings.append(f"有 {unconfirmed} 处 [待确认]：确认前面试 AI 看不到这些分句（--ai-view 预览）")
    if missing:
        warnings.append(f"有 {missing} 处 [待补充]：需要本人填写")
    if fake:
        errors.append(f"发现疑似编造的占位符 {sorted(set(fake))}，请改成 [待补充] 或真实内容")

    stats = {
        "name": meta.get("name", ""),
        "sections": [SECTIONS[s][0] for s in SECTIONS if strip_comments(sections.get(s, "")).strip()],
        "projects": len(projects),
        "stories": len(re.findall(r"^###\s+", sections.get("stories", ""), flags=re.M)),
        "unconfirmed": unconfirmed,
        "missing": missing,
        "chars": len(body),
    }
    return {"errors": errors, "warnings": warnings, "info": info, "stats": stats}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    path = args[0]
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        print(f"读取失败：{e}")
        sys.exit(2)

    if "--ai-view" in sys.argv:
        print(ai_view(text), end="")
        sys.exit(0)

    result = validate(text)
    if not path.endswith(".a2hcard"):
        result["warnings"].insert(0, "文件后缀应为 .a2hcard")

    if "--json" in sys.argv:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        s = result["stats"]
        if s:
            print(f"角色卡：{s['name']}  |  章节 {len(s['sections'])} 个  |  项目 {s['projects']} 个  |  "
                  f"故事 {s['stories']} 个  |  {s['chars']} 字")
        for e in result["errors"]:
            print(f"❌ {e}")
        for w in result["warnings"]:
            print(f"⚠️  {w}")
        for i in result["info"]:
            print(f"ℹ️  {i}")
        print("✅ 校验通过" if not result["errors"] else f"校验失败：{len(result['errors'])} 个错误")
    sys.exit(1 if result["errors"] else 0)


if __name__ == "__main__":
    main()

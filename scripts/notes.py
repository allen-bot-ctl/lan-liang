#!/usr/bin/env python3
"""发版说明工具（无第三方依赖）。

  notes.py md   VERSION   输出 Markdown：release-notes/vVERSION.md，缺失时用通用模板
  notes.py html VERSION   输出简单 HTML（供 appcast <description> 的 CDATA）
支持：# 标题、- 列表、空行分段、行内 `code` 与 **粗体**。先转义 & < >，输出保证不含 ]]>。
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env():
    env = {}
    for line in open(os.path.join(ROOT, "project.env"), encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def markdown(version):
    p = os.path.join(ROOT, "release-notes", f"v{version}.md")
    if os.path.isfile(p):
        return open(p, encoding="utf-8").read()
    env = load_env()
    tpl = open(os.path.join(ROOT, "scripts", "generic-notes.md.tpl"), encoding="utf-8").read()
    for k, v in {"__DISPLAY_NAME__": env["DISPLAY_NAME"], "__NAME__": env["NAME"],
                 "__VERSION__": version, "__TAG__": "v" + version}.items():
        tpl = tpl.replace(k, v)
    return tpl


def inline(s):
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    return s


def to_html(md):
    out, para, in_list = [], [], False

    def flush_para():
        if para:
            out.append("<p>" + " ".join(inline(x) for x in para) + "</p>")
            para.clear()

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in md.splitlines():
        line = raw.strip()
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if not line:
            flush_para(); close_list()
        elif m:
            flush_para(); close_list()
            n = len(m.group(1))
            out.append(f"<h{n}>{inline(m.group(2))}</h{n}>")
        elif re.match(r"^[-*]\s+", line):
            flush_para()
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append("<li>" + inline(re.sub(r"^[-*]\s+", "", line)) + "</li>")
        else:
            close_list(); para.append(line)
    flush_para(); close_list()
    html = "\n".join(out).replace("]]>", "]]&gt;")
    assert "]]>" not in html
    return html


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("md", "html"):
        sys.exit("用法: notes.py md|html VERSION")
    ver = sys.argv[2].lstrip("v")
    md = markdown(ver)
    sys.stdout.write(md if sys.argv[1] == "md" else to_html(md) + "\n")

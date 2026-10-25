"""模型在聊天里生成的文件：文字类原样存，Word / PDF 由这里排出来。

模型交来的是「文件名 + 内容」。文字类（txt、md、csv、代码……）内容就是文件本身；
docx 和 pdf 的内容按 Markdown 写——标题、段落、列表、粗体斜体、引用、代码块、
分隔线、表格——这里照着排成真正的文档。

PDF 要嵌一个带中文的字体，不然中文全是方块。字体不进仓库（几十 MB），用服务器
系统里装着的：Noto CJK、文泉驿……找不到就报一句清楚的错，让模型换成 Word。
可以用环境变量 DWELL_PDF_FONT 直接指一个字体文件。
"""
from __future__ import annotations

import io
import os
import re
import unicodedata

MAX_CONTENT_CHARS = 400_000
MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_NAME_CHARS = 120

TEXT_TYPES = {
    "txt": "text/plain", "md": "text/markdown", "markdown": "text/markdown",
    "csv": "text/csv", "tsv": "text/tab-separated-values", "json": "application/json",
    "html": "text/html", "htm": "text/html", "xml": "application/xml",
    "yaml": "text/yaml", "yml": "text/yaml", "toml": "text/plain", "ini": "text/plain",
    "log": "text/plain", "srt": "text/plain", "vtt": "text/vtt", "tex": "text/plain",
    "py": "text/plain", "js": "text/plain", "ts": "text/plain", "css": "text/css",
    "sh": "text/plain", "sql": "text/plain", "swift": "text/plain", "java": "text/plain",
    "c": "text/plain", "cpp": "text/plain", "h": "text/plain", "go": "text/plain",
    "rs": "text/plain", "rb": "text/plain", "php": "text/plain", "kt": "text/plain",
}
DOC_TYPES = {
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "pdf": "application/pdf",
}
SUPPORTED = sorted(TEXT_TYPES) + sorted(DOC_TYPES)


def clean_name(raw: object) -> str:
    """文件名只留能安全落地的字：去掉路径、控制字符，太长就截。"""
    name = unicodedata.normalize("NFC", str(raw or "")).strip()
    name = name.replace("\\", "/").split("/")[-1]
    name = "".join(ch for ch in name if ch.isprintable() and ch not in '<>:"|?*')
    name = re.sub(r"\s+", " ", name).strip(" .")
    if not name:
        raise ValueError("要有文件名，带扩展名，比如 笔记.md")
    if "." not in name:
        raise ValueError("文件名要带扩展名，比如 笔记.md、报告.docx、清单.pdf")
    stem, ext = name.rsplit(".", 1)
    if len(name) > MAX_NAME_CHARS:
        name = stem[:MAX_NAME_CHARS - len(ext) - 1] + "." + ext
    return name


def make_file(filename: object, content: object) -> tuple[str, str, bytes]:
    """返回 (文件名, MIME, 文件内容)。"""
    name = clean_name(filename)
    ext = name.rsplit(".", 1)[1].lower()
    text = str(content or "")
    if not text.strip():
        raise ValueError("文件内容是空的")
    if len(text) > MAX_CONTENT_CHARS:
        raise ValueError(f"内容太长了（{len(text)} 字），一份文件最多 {MAX_CONTENT_CHARS} 字")
    if ext in TEXT_TYPES:
        data = text.encode("utf-8")
        if ext in {"csv", "tsv"}:
            data = b"\xef\xbb\xbf" + data      # 带 BOM，Excel 打开中文才不乱码
        mime = TEXT_TYPES[ext]
    elif ext == "docx":
        data, mime = markdown_to_docx(text), DOC_TYPES["docx"]
    elif ext == "pdf":
        data, mime = markdown_to_pdf(text), DOC_TYPES["pdf"]
    else:
        raise ValueError("不支持 ." + ext + "。能做的：" + "、".join(SUPPORTED))
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("生成的文件超过 10 MB，拆成几份再做")
    return name, mime, data


# ---------------------------------------------------------------- Markdown 拆块

_LIST = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
_RULE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
_TABLE_SEP = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def _cells(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [cell.strip() for cell in line.split("|")]


def blocks(text: str) -> list[dict]:
    """把 Markdown 拆成块：heading / para / list / quote / code / rule / table。"""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out: list[dict] = []
    para: list[str] = []
    i = 0

    def flush():
        if para:
            out.append({"type": "para", "text": " ".join(s.strip() for s in para)})
            para.clear()

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("```"):
            flush()
            body = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                body.append(lines[i])
                i += 1
            out.append({"type": "code", "text": "\n".join(body)})
            i += 1
            continue
        if not stripped:
            flush()
            i += 1
            continue
        m = _HEADING.match(stripped)
        if m:
            flush()
            out.append({"type": "heading", "level": len(m.group(1)), "text": m.group(2)})
            i += 1
            continue
        if _RULE.match(stripped):
            flush()
            out.append({"type": "rule"})
            i += 1
            continue
        if "|" in stripped and i + 1 < len(lines) and _TABLE_SEP.match(lines[i + 1]):
            flush()
            rows = [_cells(stripped)]
            i += 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                rows.append(_cells(lines[i]))
                i += 1
            width = max(len(r) for r in rows)
            out.append({"type": "table", "rows": [r + [""] * (width - len(r)) for r in rows]})
            continue
        m = _LIST.match(line)
        if m:
            flush()
            items = []
            while i < len(lines):
                m = _LIST.match(lines[i])
                if not m:
                    break
                items.append({"level": len(m.group(1).expandtabs(4)) // 2,
                              "ordered": m.group(2)[0].isdigit(), "text": m.group(3)})
                i += 1
            out.append({"type": "list", "items": items})
            continue
        if stripped.startswith(">"):
            flush()
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip()[1:].strip())
                i += 1
            out.append({"type": "quote", "text": " ".join(q for q in quote if q)})
            continue
        para.append(line)
        i += 1
    flush()
    return out


_INLINE = re.compile(r"(\*\*[^*]+\*\*|__[^_]+__|\*[^*\s][^*]*\*|_[^_\s][^_]*_|`[^`]+`)")


def inline_runs(text: str) -> list[tuple[str, str]]:
    """一行字拆成 (样式, 字)：样式是 '' / 'b' / 'i' / 'code'。链接只留文字。"""
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1（\2）", text)
    runs = []
    for part in _INLINE.split(text):
        if not part:
            continue
        if part.startswith(("**", "__")) and len(part) > 4:
            runs.append(("b", part[2:-2]))
        elif part.startswith("`") and len(part) > 2:
            runs.append(("code", part[1:-1]))
        elif part[0] in "*_" and part[-1] == part[0] and len(part) > 2:
            runs.append(("i", part[1:-1]))
        else:
            runs.append(("", part))
    return runs


def plain(text: str) -> str:
    return "".join(t for _, t in inline_runs(text))


# ---------------------------------------------------------------- Word

def markdown_to_docx(text: str) -> bytes:
    from docx import Document
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml.ns import qn
    from docx.shared import Pt, RGBColor

    doc = Document()
    for style_name in ("Normal", "Title", "Heading 1", "Heading 2", "Heading 3",
                       "Heading 4", "Quote", "List Bullet", "List Number"):
        try:
            style = doc.styles[style_name]
        except KeyError:
            continue
        style.font.name = "Helvetica"
        rpr = style.element.get_or_add_rPr()
        fonts = rpr.find(qn("w:rFonts"))
        if fonts is None:
            fonts = rpr.makeelement(qn("w:rFonts"), {})
            rpr.append(fonts)
        fonts.set(qn("w:eastAsia"), "PingFang SC")
        if style_name.startswith("Heading") or style_name == "Title":
            style.font.color.rgb = RGBColor(0x2B, 0x26, 0x29)
    doc.styles["Normal"].font.size = Pt(11)

    def add_runs(paragraph, line: str):
        for kind, chunk in inline_runs(line):
            run = paragraph.add_run(chunk)
            if kind == "b":
                run.bold = True
            elif kind == "i":
                run.italic = True
            elif kind == "code":
                run.font.name = "Menlo"
                run.font.size = Pt(10)

    for block in blocks(text):
        kind = block["type"]
        if kind == "heading":
            add_runs(doc.add_heading("", level=min(block["level"], 4)), block["text"])
        elif kind == "para":
            add_runs(doc.add_paragraph(), block["text"])
        elif kind == "list":
            for item in block["items"]:
                style = "List Number" if item["ordered"] else "List Bullet"
                if item["level"] >= 1:
                    style += " 2"
                try:
                    paragraph = doc.add_paragraph(style=style)
                except KeyError:
                    paragraph = doc.add_paragraph(style="List Number" if item["ordered"] else "List Bullet")
                add_runs(paragraph, item["text"])
        elif kind == "quote":
            add_runs(doc.add_paragraph(style="Quote"), block["text"])
        elif kind == "code":
            paragraph = doc.add_paragraph()
            run = paragraph.add_run(block["text"])
            run.font.name = "Menlo"
            run.font.size = Pt(9.5)
        elif kind == "rule":
            paragraph = doc.add_paragraph("—" * 12)
            paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
        elif kind == "table":
            rows = block["rows"]
            table = doc.add_table(rows=len(rows), cols=len(rows[0]))
            table.style = "Table Grid"
            for r, row in enumerate(rows):
                for c, cell in enumerate(row):
                    paragraph = table.cell(r, c).paragraphs[0]
                    add_runs(paragraph, cell)
                    if r == 0:
                        for run in paragraph.runs:
                            run.bold = True
    buffer = io.BytesIO()
    doc.save(buffer)
    return buffer.getvalue()


# ---------------------------------------------------------------- PDF

_FONT_CANDIDATES = [
    # (常规, 粗体)；粗体没有就用常规的
    ("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"),
    ("/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc", "/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc"),
    ("/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc", "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Bold.ttc"),
    ("/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Regular.ttc", "/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Bold.ttc"),
    ("/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc", "/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc"),
    ("/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", ""),
    ("/usr/share/fonts/wqy-microhei/wqy-microhei.ttc", ""),
    ("/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc", ""),
    ("/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc", ""),
    ("/System/Library/Fonts/PingFang.ttc", ""),
]


def find_cjk_font() -> tuple[str, str]:
    """(常规字体路径, 粗体字体路径)。找不到返回 ('', '')。"""
    forced = os.environ.get("DWELL_PDF_FONT", "").strip()
    if forced and os.path.isfile(forced):
        return forced, ""
    for regular, bold in _FONT_CANDIDATES:
        if os.path.isfile(regular):
            return regular, bold if bold and os.path.isfile(bold) else ""
    return "", ""


def _collection_index(path: str) -> int:
    """.ttc 里有好几套字体（日韩简繁）。挑简体中文那套，挑不出就第一套。"""
    if not path.lower().endswith(".ttc"):
        return 0
    try:
        from fontTools.ttLib import TTCollection
        names = []
        for font in TTCollection(path).fonts:
            names.append(str(font["name"].getDebugName(1) or ""))
        for wanted in (" SC", "SC ", "CN", "GB", "Hei", "Micro"):
            for index, name in enumerate(names):
                if wanted in name:
                    return index
    except Exception:
        pass
    return 0


_CLOSE = set("，。、；：？！）》」』】〉”’…—,.;:?!)]}%")
_OPEN = set("（《「『【〈“‘([{")


def _cjk(ch: str) -> bool:
    code = ord(ch)
    return (0x2E80 <= code <= 0x9FFF or 0xF900 <= code <= 0xFAFF
            or 0xFF00 <= code <= 0xFFEF or 0x3000 <= code <= 0x303F)


def breakable(text: str) -> str:
    """PDF 那边只在空格处换行，中文没有空格，一整段会被当成一个「词」整块挪到下一行。
    在中文字之间塞零宽空格当换行点；不塞在「，。」这类收尾标点前面，免得它跑到行首。"""
    out = []
    for i, ch in enumerate(text):
        out.append(ch)
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if nxt and (_cjk(ch) or _cjk(nxt)) and nxt not in _CLOSE and ch not in _OPEN \
                and not ch.isspace() and not nxt.isspace():
            out.append("\u200b")
    return "".join(out)


def markdown_to_pdf(text: str) -> bytes:
    from fpdf import FPDF
    from fpdf.enums import TextMode, XPos, YPos

    regular, bold = find_cjk_font()
    if not regular:
        raise ValueError("服务器上没有中文字体，PDF 排不出来。先做成 .docx，或者请她在服务器上跑一次 deploy.sh 装字体")

    pdf = FPDF(format="A4")
    pdf.set_margins(20, 20, 20)
    pdf.set_auto_page_break(True, margin=18)
    pdf.add_font("cjk", "", regular, collection_font_number=_collection_index(regular))
    bold_path = bold or regular
    pdf.add_font("cjk", "B", bold_path, collection_font_number=_collection_index(bold_path))
    # 零宽空格只是换行点。字体里没这个字形时库会按默认宽度往前挪，字却不画，
    # 每段粗体、代码的前后就空出一截——把它的宽度钉成 0。
    for font in pdf.fonts.values():
        if hasattr(font, "cw"):
            font.cw[0x200B] = 0
    pdf.add_page()
    width = pdf.w - pdf.l_margin - pdf.r_margin
    ink, dim = (43, 38, 41), (120, 112, 116)
    pdf.set_text_color(*ink)

    def run_font(bold_run: bool, size: float):
        """有粗体字体就用；没有（文泉驿这种只有一个字重）就描边假装加粗。"""
        pdf.set_font("cjk", "B" if bold_run else "", size)
        if bold_run and not bold:
            pdf.text_mode = TextMode.FILL_STROKE
            pdf.set_line_width(size * 0.018)
            pdf.set_draw_color(*pdf_ink())
        else:
            pdf.text_mode = TextMode.FILL

    def pdf_ink():
        return dim if quoting[0] else ink

    quoting = [False]

    def write_runs(line: str, size: float, height: float, bold_all: bool = False):
        for kind, chunk in inline_runs(line):
            run_font(bold_all or kind == "b", size)
            pdf.write(height, breakable(chunk))
        pdf.text_mode = TextMode.FILL

    def write_line(line: str, size: float, height: float, indent: float = 0, bold_all: bool = False):
        """一段带粗体的字，自动换行。斜体和行内代码在 PDF 里按普通字排。"""
        pdf.set_left_margin(pdf.l_margin + indent)
        pdf.set_x(pdf.l_margin)
        write_runs(line, size, height, bold_all)
        pdf.set_left_margin(pdf.l_margin - indent)
        pdf.ln(height)

    heading_sizes = {1: 20, 2: 16, 3: 14, 4: 12.5, 5: 12, 6: 11.5}
    for block in blocks(text):
        kind = block["type"]
        if kind == "heading":
            size = heading_sizes[block["level"]]
            pdf.ln(3 if block["level"] > 1 else 1)
            write_line(block["text"], size, size * 0.55, bold_all=True)
            pdf.ln(1.5)
        elif kind == "para":
            write_line(block["text"], 11, 6.4)
            pdf.ln(2.2)
        elif kind == "list":
            number = 0
            for item in block["items"]:
                indent = 4 + item["level"] * 6
                if item["ordered"]:
                    number += 1
                    mark = f"{number}."
                else:
                    mark = "●"                # 「•」不少中文字体里没有，「●」都有
                pdf.set_font("cjk", "", 6.5 if mark == "●" else 11)
                pdf.set_x(pdf.l_margin + indent)
                pdf.cell(6, 6.4, mark)
                pdf.set_left_margin(pdf.l_margin + indent + 6)
                write_runs(item["text"], 11, 6.4)
                pdf.set_left_margin(pdf.l_margin - indent - 6)
                pdf.ln(6.4)
            pdf.ln(2)
        elif kind == "quote":
            pdf.set_text_color(*dim)
            quoting[0] = True
            top = pdf.get_y()
            write_line(block["text"], 11, 6.4, indent=6)
            quoting[0] = False
            pdf.set_draw_color(220, 200, 210)
            pdf.set_line_width(0.8)
            pdf.line(pdf.l_margin + 1.5, top, pdf.l_margin + 1.5, pdf.get_y())
            pdf.set_text_color(*ink)
            pdf.ln(2)
        elif kind == "code":
            pdf.set_font("cjk", "", 9.5)
            pdf.set_fill_color(246, 242, 244)
            pdf.multi_cell(width, 5.2, block["text"] or " ", fill=True,
                           new_x=XPos.LMARGIN, new_y=YPos.NEXT)
            pdf.ln(2.5)
        elif kind == "rule":
            pdf.set_draw_color(220, 214, 217)
            pdf.set_line_width(0.3)
            y = pdf.get_y() + 2
            pdf.line(pdf.l_margin, y, pdf.w - pdf.r_margin, y)
            pdf.ln(5)
        elif kind == "table":
            pdf.set_font("cjk", "", 10)
            pdf.set_draw_color(220, 214, 217)
            with pdf.table(width=width, line_height=6) as table:   # 第一行当表头，粗体
                for row in block["rows"]:
                    cells = table.row()
                    for cell in row:
                        cells.cell(plain(cell))
            pdf.set_font("cjk", "", 11)
            pdf.ln(3)
    return bytes(pdf.output())

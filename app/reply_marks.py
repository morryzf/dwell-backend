"""回复里的小记号：Cloudy 在回复里顺手写的 [[react:🥺]]、[[quote:那几个字]]。

不做成工具：工具每调一次就要把整段上下文再发给模型一遍。记号是回复的一部分，
边说边认出来、做掉，再从显示的文字里摘掉，Morry 看不到记号本身。

只认 react 和 quote 两种；[[sigillo:…]]、[[shop:…]] 这些卡片记号原样留着，前端要靠它们画卡片。
"""

from __future__ import annotations

import re

KINDS = ("react", "quote")
MARK_RE = re.compile(r"\[\[(react|quote):(.*?)\]\]", re.S)
# 等一个记号收尾最多等这么多字；再长、或者换了行，就不是记号，原样放出去。
MAX_MARK = 300


def strip_marks(text: str) -> str:
    """去掉文字里所有的 react / quote 记号（判断语言、比对原文时用）。"""
    return MARK_RE.sub("", str(text or ""))


class MarkFilter:
    """边流边认记号。feed 一段吐出能显示的那段；记号本身收进 marks 里交给调用方处理。

    看到「[[」就先扣住后面的字，等「]]」来了再决定：是记号就摘掉，不是就原样放出去。
    """

    def __init__(self) -> None:
        self.pending = ""
        self.marks: list[tuple[str, str]] = []

    def feed(self, chunk: str, final: bool = False) -> str:
        text = self.pending + str(chunk or "")
        self.pending = ""
        out: list[str] = []
        while text:
            start = text.find("[[")
            if start < 0:
                # 结尾一个孤零零的「[」可能是下一个记号的开头，先扣着。
                if text.endswith("[") and not final:
                    out.append(text[:-1])
                    self.pending = "["
                else:
                    out.append(text)
                break
            out.append(text[:start])
            rest = text[start:]
            end = rest.find("]]")
            if end < 0:
                if final or len(rest) > MAX_MARK or "\n" in rest:
                    out.append(rest[:2])
                    text = rest[2:]
                    continue
                self.pending = rest
                break
            whole = rest[:end + 2]
            match = MARK_RE.fullmatch(whole)
            if match:
                self.marks.append((match.group(1), match.group(2).strip()))
            else:
                out.append(whole)
            text = rest[end + 2:]
        return "".join(out)

    def flush(self) -> str:
        return self.feed("", final=True)

    def take(self) -> list[tuple[str, str]]:
        marks, self.marks = self.marks, []
        return marks


def parse_react(value: str) -> tuple[str, int]:
    """「🥺」或「🥺|1」：表情，往前数第几条（0 = 她最新那条）。"""
    emoji, _, back = str(value or "").partition("|")
    try:
        return emoji.strip(), max(0, int(back.strip() or 0))
    except ValueError:
        return emoji.strip(), 0

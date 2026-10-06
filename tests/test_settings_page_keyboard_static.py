"""设置里推进来的整页遇到键盘：原地不动，正文自己滚；重写规则不再和聊天指令共用图标。"""

from pathlib import Path

INDEX = Path("static/index.html").read_text(encoding="utf-8")


def test_full_page_settings_are_not_lifted_by_the_keyboard():
    assert "if (sheet.closest('.sheetWrap.sub')) { fitFullPageSheetToKeyboard(sheet, vv, keyboardOn); continue; }" in INDEX
    helper = INDEX.split("function fitFullPageSheetToKeyboard", 1)[1].split("\nfunction ", 1)[0]
    assert "sheet.style.transform = ''" in helper
    assert "body.style.paddingBottom = pad + 'px'" in helper


def test_rewrite_rules_has_its_own_icon():
    assert 'id="rewriteRulesRow"><span class="ic" data-i="refresh"></span>重写规则' in INDEX
    assert 'id="instructionsRow"><span class="ic" data-i="layers"></span>聊天指令' in INDEX

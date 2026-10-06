from pathlib import Path

INDEX = Path("static/index.html").read_text(encoding="utf-8")


def test_preview_mode_tabs_do_not_change_app_theme():
    handler = INDEX.split("body.querySelectorAll('[data-style-tab]')", 1)[1].split("});", 1)[0]
    assert "messageStyleTab = btn.dataset.styleTab;" in handler
    assert "wearTheme(" not in handler
    assert "applyMessageStyleMode(" not in handler


def test_only_active_theme_edits_update_live_chat():
    guard = "if (messageStyleTab === effectiveMessageStyleMode()) applyMessageStyles();"
    # 「复制给…」按钮删掉之后，只剩调节样式这一处会改到聊天里的气泡。
    assert INDEX.count(guard) >= 1


def test_each_assistant_has_its_own_bubble_style_and_no_copy_button():
    assert "const MESSAGE_STYLE_ROLES = ['me', 'cloudy', 'chatgpt'];" in INDEX
    assert "messageStyleCopy" not in INDEX
    assert "msg-style-copy" not in INDEX
    # 聊天里助手气泡那组变量写的是当前那位助手的值
    assert "messageStyleState[assistantId === 'chatgpt' ? 'chatgpt' : 'cloudy'][mode]" in INDEX


def test_chat_background_is_kept_per_assistant():
    assert "return (who || assistantId) === 'chatgpt' ? base + ':chatgpt' : base;" in INDEX
    assert "localStorage.getItem('dwellChatBackground' + suffix)" in INDEX

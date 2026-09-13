from pathlib import Path

INDEX = Path("static/index.html").read_text(encoding="utf-8")


def test_preview_mode_tabs_do_not_change_app_theme():
    handler = INDEX.split("body.querySelectorAll('[data-style-tab]')", 1)[1].split("});", 1)[0]
    assert "messageStyleTab = btn.dataset.styleTab;" in handler
    assert "wearTheme(" not in handler
    assert "applyMessageStyleMode(" not in handler


def test_only_active_theme_edits_update_live_chat():
    guard = "if (messageStyleTab === effectiveMessageStyleMode()) applyMessageStyles();"
    assert INDEX.count(guard) >= 2

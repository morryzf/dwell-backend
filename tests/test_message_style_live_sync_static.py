from pathlib import Path

INDEX = Path("static/index.html").read_text(encoding="utf-8")


def test_message_style_mode_is_applied_explicitly():
    assert "function applyMessageStyleMode(mode)" in INDEX
    assert "applyMessageStyleMode(effectiveMessageStyleMode());" in INDEX


def test_mode_tabs_switch_live_interface_before_editing():
    handler = INDEX.split("body.querySelectorAll('[data-style-tab]')", 1)[1].split("});", 1)[0]
    assert "wearTheme(messageStyleTab);" in handler
    assert "applyMessageStyleMode(messageStyleTab);" in handler


def test_message_controls_update_live_chat_profile():
    assert "writeMessageRoleStyle(preview.style, messageStyleRole, current);\n      applyMessageStyleMode(messageStyleTab); saveMessageStyles();" in INDEX

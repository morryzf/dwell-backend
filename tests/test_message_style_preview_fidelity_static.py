from pathlib import Path

INDEX = Path("static/index.html").read_text(encoding="utf-8")


def test_message_preview_uses_same_glass_depth_as_live_bubbles():
    shadow = "inset 0 1px 0 rgba(255,255,255,.16), 0 6px 20px rgba(72,54,64,.075)"
    assert INDEX.count(shadow) >= 3
    assert "#messageStyleSheet .sheet {" in INDEX
    assert "backdrop-filter: none !important;" in INDEX


def test_custom_background_preview_keeps_viewport_crop():
    block = INDEX.split("html.has-chat-background .msg-style-preview {", 1)[1].split("}", 1)[0]
    assert "background-attachment: fixed;" in block

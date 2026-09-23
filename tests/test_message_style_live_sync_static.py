from pathlib import Path

INDEX = Path("static/index.html").read_text(encoding="utf-8")


def test_message_style_mode_is_applied_explicitly():
    assert "function applyMessageStyleMode(mode)" in INDEX
    assert "applyMessageStyleMode(effectiveMessageStyleMode());" in INDEX


# 原本还有 test_mode_tabs_switch_live_interface_before_editing 和
# test_message_controls_update_live_chat_profile，断言明暗标签会把整个 app 主题
# 一起切过去（#140 的行为）。第二天 #142「让玻璃明暗标签只切换预览」把这个行为
# 改掉了，并在 test_message_style_preview_mode_static.py 里写了断言相反行为的
# 新测试——但忘了删这两个，于是两份测试互相打架、这两个一直红着。
# 当前行为由那份新测试守着，这两个已被取代。

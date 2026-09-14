from pathlib import Path


INDEX = (Path(__file__).parents[1] / "static" / "index.html").read_text(encoding="utf-8")


def test_cache_checkpoint_divider_is_rendered_live_and_from_history():
    assert "function addCacheCheckpointDivider(messageId)" in INDEX
    assert "已达50条缓存点，下一条将重新缓存" in INDEX
    assert "if (d.type === 'cache_checkpoint')" in INDEX
    assert "m.usage.cache_checkpoint" in INDEX


def test_timeline_dividers_reverse_contrast_with_the_theme_text_color():
    rule = INDEX.index(".proactive-divider {")
    pseudo_rule = INDEX.index(".proactive-divider::before", rule)
    assert "var(--text) 58%" in INDEX[rule:pseudo_rule]
    assert "var(--text) 40%" in INDEX[pseudo_rule:pseudo_rule + 240]

"""语音设置页：顶上选给谁设，声音卡 + 朗读设置是这位自己的，音色库和连接两位共用，改了就存。"""

from pathlib import Path

HTML = (Path(__file__).parents[1] / "static" / "index.html").read_text(encoding="utf-8")
PAGE = HTML.split("function renderTtsSettings(cfg) {", 1)[1].split("document.getElementById('ttsRow').onclick", 1)[0]


def test_tts_connection_credentials_are_collapsible():
    assert 'id="ttsConnectionToggle"' in PAGE
    assert 'id="ttsConnection"' in PAGE
    assert "connection.hidden = !willOpen" in PAGE
    assert '#ttsConnectionToggle[aria-expanded="true"] .chev' in HTML


def test_settings_are_chosen_per_assistant():
    assert "data-tts-assistant" in PAGE
    assert "postTtsConfig({assistant: who, ...patch})" in PAGE
    assert "'api/tts/config?assistant=' + encodeURIComponent(who)" in HTML
    # 打开时先设当前聊天的那位
    assert "ttsEditAssistant = assistantId;" in HTML


def test_page_saves_as_you_go_without_a_save_button():
    assert 'id="ttsSave"' not in HTML
    assert "tts-voice-card" not in HTML
    assert '.tts-settings input[type="checkbox"]' not in HTML
    assert "tts-seg" in PAGE and 'class="sw' in PAGE


def test_storage_stays_after_the_shared_groups():
    assert PAGE.index("音色库 · 两位共用") < PAGE.index("连接 · 两位共用") < PAGE.index('class="group tts-storage"')


def test_switching_assistant_reloads_the_voice_used_for_playback():
    assert "if (typeof loadTtsConfig === 'function') loadTtsConfig().catch(() => {});" in HTML

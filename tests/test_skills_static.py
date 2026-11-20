import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "static" / "index.html").read_text(encoding="utf-8")


class SkillsSheetStaticTest(unittest.TestCase):
    """设置里的 Skills 页：列表、开关、编辑器都走 api/skills。"""

    def test_settings_row_opens_the_sheet(self):
        self.assertIn('id="skillsRow"', HTML)
        self.assertIn('id="skillsSheet"', HTML)
        self.assertIn("skills: document.getElementById('skillsSheet')", HTML)

    def test_it_talks_to_the_skills_api(self):
        self.assertIn("'api/skills'", HTML)
        self.assertIn("'api/skills/' + encodeURIComponent(", HTML)
        self.assertIn("method:'PATCH'", HTML)
        self.assertIn("method:'DELETE'", HTML)

    def test_copy(self):
        self.assertIn("写给 Cloudy 的做法：平时他只看到名字和「什么时候用」，对得上的时候自己打开读。", HTML)
        self.assertIn("什么时候用", HTML)
        self.assertIn("比如：Morry 难过、哭了、说自己不好的时候", HTML)
        self.assertIn("写得越具体，他越容易在对的时候想起来", HTML)
        self.assertIn("具体怎么做……", HTML)

    def test_inputs_do_not_trigger_ios_zoom(self):
        self.assertIn("#skillsBody .ap-in { font-size: 16px; }", HTML)


if __name__ == "__main__":
    unittest.main()

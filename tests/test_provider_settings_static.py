from pathlib import Path
import unittest


class ProviderSettingsStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).parents[1]
        cls.ui = (root / "static" / "index.html").read_text(encoding="utf-8")

    def test_saved_providers_are_name_only_rows_with_a_separate_add_action(self):
        self.assertIn('id="apProviderList"', self.ui)
        self.assertIn('id="apAddProvider"', self.ui)
        self.assertIn("row.onclick = () => openProviderEditor(p.id);", self.ui)
        self.assertIn("name.textContent = p.name;", self.ui)
        self.assertNotIn('id="apProfile"', self.ui)
        self.assertNotIn("＋ 新供应商</option>", self.ui)

    def test_provider_configuration_stays_hidden_until_requested(self):
        self.assertIn('id="apEditor" hidden', self.ui)
        self.assertIn("editor.hidden = false;", self.ui)
        self.assertIn("document.getElementById('apAddProvider').onclick = () => openProviderEditor('');", self.ui)
        self.assertIn("document.getElementById('apCancel').onclick = closeEditor;", self.ui)

    def test_editing_without_a_new_token_preserves_the_saved_key(self):
        self.assertIn("if (token || !editingProviderId) value.token = token;", self.ui)

    def test_settings_catalog_does_not_expose_chat_model_switching(self):
        self.assertIn("openProviderModelPicker('browse', 'settings')", self.ui)
        self.assertIn("const settingsCatalog = catalogOrigin === 'settings';", self.ui)
        self.assertIn("if (!settingsCatalog) {", self.ui)
        self.assertIn("if (!settingsCatalog && catalogMode === 'favorites') {", self.ui)
        self.assertIn("modelBack.appendChild(icEl(settingsCatalog ? 'chevL' : 'x', 16));", self.ui)
        self.assertIn("openProviderModelPicker('favorites', 'chat')", self.ui)

    def test_model_catalog_description_is_visually_secondary(self):
        self.assertIn(
            ".ap-section-description { margin: 2px 0 0; color: var(--dim); "
            "font-size: 12.5px; line-height: 1.55; }",
            self.ui,
        )
        self.assertIn(
            '<div class="ap-section-description">获取供应商的模型后，挑进常用模型；'
            '聊天页只显示常用项。</div>',
            self.ui,
        )


if __name__ == "__main__":
    unittest.main()

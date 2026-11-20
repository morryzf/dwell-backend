"""Skills：她写的做法说明。他每轮只看到目录，需要时自己打开读正文。"""

import asyncio
import os
import unittest
import uuid

from fastapi.testclient import TestClient

from app import auth, db, main


class SkillTest(unittest.TestCase):
    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"skills-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("c", assistant=db.DEFAULT_ASSISTANT)["id"]
        self.client = TestClient(main.app)
        main.app.dependency_overrides[auth.require_auth] = lambda: None

    def tearDown(self):
        main.app.dependency_overrides.pop(auth.require_auth, None)
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def _add(self, **kw):
        r = self.client.post("/api/skills", json={"name": "她难过的时候", "when_text": "她低落、哭了",
                                                  "body": "先抱住她，别急着讲道理。", **kw})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()["item"]

    def test_he_sees_the_list_not_the_body_and_can_open_it(self):
        skill = self._add()
        _, _, format_preference, _ = main._chat_stable_message_parts(self.chat)
        listing = next(m["content"] for m in format_preference if "[Skills]" in m["content"])
        self.assertIn("她难过的时候: 她低落、哭了", listing)
        self.assertNotIn("先抱住她", listing)

        _, tool_map = asyncio.run(main._chat_tools(self.chat))
        self.assertEqual(tool_map["DwellSkill"], "builtin:skill")
        text, is_error = asyncio.run(main._run_chat_tool(self.chat, "DwellSkill", "builtin:skill",
                                                         {"name": " 她难过的时候 "}))
        self.assertFalse(is_error)
        self.assertIn("先抱住她", text)

        self.client.patch(f"/api/skills/{skill['id']}", json={"enabled": False})
        _, tool_map = asyncio.run(main._chat_tools(self.chat))
        self.assertNotIn("DwellSkill", tool_map)
        _, _, format_preference, _ = main._chat_stable_message_parts(self.chat)
        self.assertFalse(any("[Skills]" in m["content"] for m in format_preference))

    def test_unknown_name_lists_what_exists(self):
        self._add()
        text, is_error = asyncio.run(main._run_chat_tool(self.chat, "DwellSkill", "builtin:skill", {"name": "x"}))
        self.assertTrue(is_error)
        self.assertIn("她难过的时候", text)

    def test_names_are_unique_and_required(self):
        self._add()
        self.assertEqual(self.client.post("/api/skills", json={"name": "她难过的时候"}).status_code, 400)
        self.assertEqual(self.client.post("/api/skills", json={"name": "  "}).status_code, 400)

    def test_other_assistants_dont_get_them(self):
        self._add()
        other = db.chat_add("o", assistant="chatgpt")["id"]
        _, tool_map = asyncio.run(main._chat_tools(other))
        self.assertNotIn("DwellSkill", tool_map)
        self.assertEqual(main._skills_message(other), [])

    def test_crud(self):
        skill = self._add()
        r = self.client.patch(f"/api/skills/{skill['id']}", json={"body": "新的做法"})
        self.assertEqual(r.json()["item"]["body"], "新的做法")
        self.assertEqual(len(self.client.get("/api/skills").json()["items"]), 1)
        self.assertEqual(self.client.delete(f"/api/skills/{skill['id']}").status_code, 200)
        self.assertEqual(self.client.get("/api/skills").json()["items"], [])


if __name__ == "__main__":
    unittest.main()

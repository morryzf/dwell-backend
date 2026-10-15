import os
import unittest
import uuid

from app import agent_sdk_client, db
from app.main import _restore_reply_version


class VersionRestoreTest(unittest.TestCase):
    """拿旧版本接着聊：旧版换回来，现在这版存成旧版本，会话从头读。"""

    def setUp(self):
        self.previous_path = db.DB_PATH
        self.path = os.path.abspath(f"version-restore-test-{uuid.uuid4().hex}.sqlite3")
        db.DB_PATH = self.path
        db.init_db()
        self.chat = db.chat_add("version restore test")["id"]
        db.message_add(self.chat, "user", "duark")
        self.first = db.message_add(self.chat, "assistant", "durak, not duark")
        self.second = db.message_add(self.chat, "assistant", "Try again.")
        for item in (self.first, self.second):
            db.message_usage_update(item["id"], {"tts_turn_id": self.first["id"]})
        self.old = db.message_version_add(self.first["id"], "*grinning*\n\nDu-rak.", "regenerated")
        db.setting_set(agent_sdk_client.SESSION_SETTING_PREFIX + f"dwell-chat:{self.chat}", '{"sid": "s"}')

    def tearDown(self):
        db.DB_PATH = self.previous_path
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(self.path + suffix):
                os.remove(self.path + suffix)

    def test_a_regenerated_version_replaces_the_whole_turn(self):
        result = _restore_reply_version(self.chat, self.second["id"], self.old["id"])

        self.assertEqual(result["id"], self.first["id"])
        self.assertEqual(db.message_get(self.first["id"])["content"], "*grinning*\n\nDu-rak.")
        self.assertIsNone(db.message_get(self.second["id"]))

    def test_the_replaced_reply_is_kept_as_an_old_version(self):
        _restore_reply_version(self.chat, self.first["id"], self.old["id"])

        versions = db.message_versions(self.first["id"])
        self.assertEqual([v["content"] for v in versions], ["durak, not duark\n\nTry again."])
        self.assertEqual(versions[0]["reason"], "restored")

    def test_the_session_starts_over_so_the_model_rereads_the_chat(self):
        _restore_reply_version(self.chat, self.first["id"], self.old["id"])

        self.assertIsNone(agent_sdk_client.load_state(f"dwell-chat:{self.chat}"))

    def test_an_edited_version_only_replaces_that_message(self):
        edited = db.message_version_add(self.second["id"], "Go again.", "edited")

        _restore_reply_version(self.chat, self.second["id"], edited["id"])

        self.assertEqual(db.message_get(self.second["id"])["content"], "Go again.")
        self.assertEqual(db.message_get(self.first["id"])["content"], "durak, not duark")


if __name__ == "__main__":
    unittest.main()

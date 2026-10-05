"""网页每次打开都要问一声有没有新版，部署完手机上才看得到新页面。"""

import unittest

from fastapi.testclient import TestClient

from app import main


class PageCacheTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)

    def test_pages_must_be_revalidated(self):
        for path in ("/", "/watch", "/index.html", "/sw.js", "/some/frontend/route"):
            response = self.client.get(path)
            self.assertEqual(response.status_code, 200, path)
            self.assertEqual(response.headers.get("cache-control"), "no-cache", path)

    def test_unchanged_page_costs_a_304(self):
        first = self.client.get("/")
        again = self.client.get("/", headers={"If-None-Match": first.headers["etag"]})
        self.assertEqual(again.status_code, 304)

    def test_other_static_files_keep_default_caching(self):
        response = self.client.get("/manifest.json")
        self.assertNotEqual(response.headers.get("cache-control"), "no-cache")


if __name__ == "__main__":
    unittest.main()

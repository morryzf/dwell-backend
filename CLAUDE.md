# Dwell

- Backend: FastAPI in `app/`, SQLite. Tests: `python -m unittest discover -s tests`.
- Web: one file, `static/index.html` (vanilla HTML/CSS/JS, no build step).
- iOS app: SwiftUI in `ios/` (see `ios/README.md`). Built on GitHub Actions; the owner sideloads it.
- Deploy: a Tencent Cloud server, updated by running `./deploy.sh` there. Pushing doesn't deploy.

## iOS constraints

- Stay in **Swift 5 language mode** with an **iOS 17** deployment target. Don't migrate to Swift 6 or use APIs newer than iOS 17 without a version check. This overrides `write-swift`'s Swift 6 advice.
- The app copies the web look: measure web computed styles and reuse the tokens in `ios/Dwell/Theme.swift`.

## Design skills

`.claude/skills/` has Emil Kowalski's skills (MIT, see `THIRD_PARTY_NOTICES.md`). Web examples in them are often React or Framer Motion; translate them to vanilla CSS/JS for `static/index.html` and to SwiftUI for `ios/`.

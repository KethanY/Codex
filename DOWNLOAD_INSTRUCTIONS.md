# Download / Import Instructions (Swift Playgrounds)

If your PR system says **"binary files not supported"**, do **not** commit a `.zip` artifact.
Commit only the plain-text playground folder:

- `AdvancedMultipeerChat.playground/Contents.swift`
- `AdvancedMultipeerChat.playground/contents.xcplayground`

## Option 1: From GitHub web UI (no binary files needed)
1. Open the repo/PR in GitHub.
2. Click **Code → Download ZIP** for the repo.
3. Unzip locally.
4. Open `AdvancedMultipeerChat.playground` in Swift Playgrounds or Xcode.

## Option 2: From git locally
```bash
git clone <repo-url>
cd <repo>
open AdvancedMultipeerChat.playground
```

## Optional: make your own zip locally (outside git)
```bash
zip -r AdvancedMultipeerChat.playground.zip AdvancedMultipeerChat.playground
```
Share that zip directly, but keep it out of the PR.

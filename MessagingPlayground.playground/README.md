# Advanced Multipeer Messaging Playground

A Swift Playground chat app with iMessage-style UI and real peer-to-peer transport via `MultipeerConnectivity`.

## Features
- iMessage-style chat bubbles (sent vs received styling)
- Peer discovery + secure encrypted sessions
- Reliable JSON message transport
- Read receipts (`Sent`, `Delivered`, `Read`)
- Typing indicator
- Tap incoming message to send emoji reaction

## Run locally
1. Open `MessagingPlayground.playground` in **Swift Playgrounds** or **Xcode**.
2. Run on 2 devices/simulators on the same network.
3. Grant local network permissions when prompted.
4. Chat between peers.

## Publish to GitHub
1. Create a repository (example: `advanced-multipeer-messages-playground`).
2. Upload the full `MessagingPlayground.playground` folder.
3. Share via GitHub (users can click **Code → Download ZIP**).

## Optional: make a downloadable release asset
From repo root:

```bash
zip -r MessagingPlayground.zip MessagingPlayground.playground
```

Then attach `MessagingPlayground.zip` to a GitHub Release.

> Best behavior is on real iOS devices for Multipeer connectivity.

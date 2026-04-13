# Run as an **App** (not a Playground Book)

This repo now includes app-style SwiftUI entry code (`@main` app) so you can run it as a normal app target.

## Quick start (Xcode)
1. Create a new **iOS App** project (SwiftUI, Swift).
2. Replace the generated app/source file(s) with `AdvancedMultipeerChatPlayground.swift`.
3. In **Signing & Capabilities / Info**, ensure Local Network and Nearby Interaction permissions are allowed.
4. Build and run on two real devices on the same local network.

## Swift Playgrounds App project (iPad/Mac)
1. Create a new **App** in Swift Playgrounds (not a Book).
2. Replace the default source with `AdvancedMultipeerChatPlayground.swift`.
3. Run on two devices and grant Local Network permissions when prompted.

## Notes
- Do not use `.playgroundbook`.
- This code is app-structured and starts from:

```swift
@main
struct AdvancedMultipeerChatApp: App { ... }
```

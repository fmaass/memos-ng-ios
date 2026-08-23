# memos-ng-ios

Native SwiftUI client for [memos-ng](https://github.com/fmaass/memos-ng), and the reference iOS
project I build new iOS apps from. It talks to a memos-ng server over its REST API with a personal
access token stored in the Keychain.

Status: foundation in progress. See `docs/ARCHITECTURE.md` once Phase 3 lands.

## Building

The Xcode project is generated, not committed:

    brew install xcodegen
    xcodegen generate
    open MemosNG.xcodeproj

Gate (run from any checkout; executes on the build host): `bin/mac-gate.sh`.

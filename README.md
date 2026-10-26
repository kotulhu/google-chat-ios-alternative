# Google Chat iOS

Unofficial alternative client for Google Chat, built with Swift (no Electron,
no embedded Chrome).

This is the first stage of an iOS client for Google Chat. The app currently
runs fully locally and implements the core scenarios:

- chat list based on the `ChatSpace` concept from the macOS client;
- message list based on the `Message` concept;
- sending a text message;
- persisting chats and sent messages in `UserDefaults`.

## Running

Open `GoogleChatIOS.xcodeproj` in Xcode and run it on an iPhone or Simulator.
Command-line builds require the iOS SDK:

```bash
xcodebuild -project GoogleChatIOS.xcodeproj -scheme GoogleChatIOS \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
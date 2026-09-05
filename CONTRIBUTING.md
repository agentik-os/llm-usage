# Contributing

Issues and pull requests are welcome. For UI work, retain the monochrome design, accessibility labels, independent appearance settings and native glass fallback.

Build with Xcode 26 or newer. Run `swift test` and `python3 -m unittest discover -s Tests/BridgeTests -v` before submitting. Preview checks use synthetic accounts; real sign-in and local account checks are opt-in. See README.md for setup and integration checks.

Never attach account metadata, authentication files, tokens, Keychain exports, SSH configuration or screenshots of real accounts to issues or pull requests. Use synthetic fixtures and redacted logs.

Changes to account switching should preserve running conversations, confirm each device independently, and keep refresh credentials with the original sign-in. Cover failures, reconnects and provider isolation when changing the connector.

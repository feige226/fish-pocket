# iOS 16.4.1 compatibility build

This branch is based on the latest upstream `main` and carries the iOS 16.4 compatibility port. It is intentionally separate from both `main` and the legacy `ios16.4.1-compat` branch.

The `.github/workflows/ios-build.yml` workflow builds an unsigned physical-device IPA with Xcode 27.2 and uploads it as a short-lived Actions artifact. The app deployment target is iOS 16.4, which covers iOS 16.4.1.

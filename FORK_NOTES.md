# Bitcredit fork notes

This is the Bitcredit-maintained fork of [crowdin/flutter-sdk](https://github.com/crowdin/flutter-sdk),
used by the [BitcreditProtocol/wallet](https://github.com/BitcreditProtocol/wallet) app as a Git
dependency instead of a vendored path package.

- Upstream repository: https://github.com/crowdin/flutter-sdk
- Base tag: `1.1.2`
- Base commit: `8fd302df2d322739390ac04cb0d4f6308494566f`
- Fork branch: `bitcredit/realtime-preview-controls`
- This package is consumed exclusively as a Git dependency and is not published to
  pub.dev (`publish_to: none` in `pubspec.yaml`).

## Bitcredit modifications

- Fixed the OAuth scope used for real-time preview authentication
  (`project.translation:read`, matching what Crowdin's API actually accepts).
- Fixed parsing of WebSocket event ids: events arrive as `tr{123}` but the
  mapping data keys are the plain id (`123`); the id is now unwrapped before
  the lookup.
- Added `CrowdinMapper.toCrowdinLanguageCode` to map Flutter locale codes to
  the Crowdin-side codes used for WebSocket subscriptions (e.g. `es` -> `es-ES`),
  reusing the existing upstream locale table.
- Real-time preview no longer starts automatically just because
  configuration/credentials are present. It is now opt-in via
  `Crowdin.enableRealTimePreview()`.
- Added `CrowdinPreviewSession` / `CrowdinPreviewState`, exposing
  `Disabled`, `Authenticating`, `Connected` and `Error` states, plus
  subscription progress, through `Crowdin.realTimePreviewState`.
- Added cancellation (`Crowdin.cancelRealTimePreviewActivation()`) and retry
  support, with deduplication of concurrent activation and subscription
  attempts.
- OAuth, metadata, socket and subscription failures are now propagated to the
  session as `Error` state instead of being silently swallowed. This includes
  WebSocket subscription tickets: if any ticket fails to be created, the
  subscription attempt now throws instead of reporting subscriptions ready.
- Added a 5-minute timeout on the OAuth authorization step.
- Hardened `CrowdinPreviewManager` against missing ARB data and missing
  mapping ids (previously a missing mapping id `firstWhere` without
  `orElse` could throw).
- OAuth listeners, socket listeners and socket connections are now cleaned up
  on cancel/dispose instead of being leaked.
- `CrowdinRealTimePreviewWidget` now rebuilds via a `ValueListenable`
  revision counter and supports an `autoStart` flag so the wallet can opt
  out of automatically enabling preview on mount.
- Fixed a clean/unexpected WebSocket closure bug: the manager previously
  only handled `onError` on the socket stream, not `onDone`, so an
  unexpected clean close left the session stuck reporting `Connected`.
  `onDone` now clears connection/subscription state and reports a
  connection error (so the UI can offer Retry), unless the close was
  caused by an intentional `cancelStart()`/`dispose()` call (tracked via an
  explicit flag so those paths never report an error).
- Fixed the same class of bug for locale-change subscriptions: if
  `setPreviewArb()` triggers a re-subscription while already connected and
  that subscription fails, the manager now resets its connection/subscription
  state before reporting the error, so a subsequent Retry (`start()`) performs
  a real reconnect instead of silently no-oping because it still believed it
  was connected.
- Added constructor-level test seams to `CrowdinPreviewManager`
  (`api`, `connectWebSocket`, `createAuth`) so the real-time connection
  lifecycle — including the WebSocket `onDone`/`onError` behavior above —
  can be unit tested without a live OAuth flow or socket server.

## Syncing with upstream

```sh
git fetch upstream
git checkout bitcredit/realtime-preview-controls
git merge upstream/main   # or: git rebase upstream/main
```

Resolve conflicts, re-run `dart format`, `flutter analyze`, and `flutter test`,
and update this file if the list of Bitcredit modifications changes.

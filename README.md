# thane-ios-companion

An App Store-oriented iPhone and iPad companion that makes operator-approved
iOS context available to [Thane](https://github.com/nugget/thane-ai-agent).

The app is a data bridge, not an iOS host for the Thane daemon. While active,
it connects to `/v1/realtime/ws`, authenticates as a platform provider, and
answers on-demand requests using public Apple APIs and iOS permission controls.
It can also make short authenticated HTTPS uploads from a durable latest-value
outbox when an opted-in system event gives it background execution time.

## Current context sources

- `ios.system-context` / `ios_system_context`: an operator-approved snapshot
  of regional settings, device state, and network-path state.
- `ios.location` / `ios_current_location`: a one-shot Core Location reading
  after the operator enables sharing and grants While Using authorization.
  Significant-change background observations require a separate opt-in and
  Always authorization. iOS decides when those events are delivered.
- `ios.visits` / `ios_recent_visits`: a bounded history of reported stays,
  arrival/departure times, coordinates, and accuracy, covering up to 48 hours
  and 16 visits. Visit History requires a separate opt-in and Always
  authorization. Development builds also offer separately enabled Apple Maps
  place details; nearby businesses are candidates, not proof of occupancy.
- `ios.photos` / `ios_recent_photos`: a bounded list of recent visible-photo
  metadata after a separate in-app opt-in and Photos authorization. It includes
  PhotoKit dates, dimensions, favorite state, saved location, and selected
  EXIF/TIFF camera fields when the original is already local. It never returns
  pixels, hidden assets, raw PhotoKit identifiers, or downloads from iCloud.

Every category defaults off. A connected Thane receives only categories the
operator enabled in the app. Background events are coalesced by kind, protected
with iOS file protection, and removed only after Thane accepts them. The app
does not continuously track location or claim persistent background
availability; its realtime tools remain foreground-only.

The adaptive app shell has Chats and Settings. Chats opens the active Thane's
identity, conversations, inbox, and sharing controls. Settings owns agent
profiles, credentials, connection controls, appearance, and diagnostics.
Sharing choices belong to each counterparty.

The app reads authenticated `GET /v1/identity` evidence from the configured
Thane and exposes its stable identifier, public fingerprints, core revisions,
anchor posture, and local verification results. The operator can pin the
presented identity in Keychain. Private delivery requires matching identity
evidence; an identity mismatch blocks sharing until the operator resolves it.

API tokens are stored in Keychain. Remote servers must use HTTPS; plaintext is
accepted only for simulator-friendly loopback development. TLS verification is
never disabled.

## Image Context Preview

Development builds expose a separate, default-off Image Context Preview
in Settings. It is an app-local experiment and does not enable a Thane sharing
source. After opting in, the operator taps Choose and Analyze Image, then selects
one image with PhotosPicker. It does not scan the photo library or run in the
background. The system picker may retrieve the selected asset from iCloud;
that explicit import is separate from local inference.

The preview requires iOS 27 and an available Apple Intelligence model on a
supported device. Analysis uses only Foundation Models' `SystemLanguageModel`,
with no network or alternate-model fallback. The companion keeps selected image
bytes and bounded derived output only in memory and does not save a copy or send
them to Thane. The system Photos picker manages its own temporary transfer files.
Disabling the preview or leaving its screen cancels analysis and clears the
preview.

Physical-device model quality, latency, and memory behavior have not yet been
validated. Evaluate the preview on a supported iPhone before proposing a
Thane-facing image-context capability.

## App links

The initial `thane://` routes are read-only and versioned. They carry bounded
routing identifiers only:

- `thane://v1/agents/<thane-identity-id>`
- `thane://v1/agents/<thane-identity-id>/conversations`
- `thane://v1/agents/<thane-identity-id>/conversations/<conversation-id>`
- `thane://v1/agents/<thane-identity-id>/inbox`
- `thane://v1/agents/<thane-identity-id>/inbox/<item-id>`

Reserved characters in identifiers must be percent encoded. The app rejects
unknown versions and destinations, credentials, ports, query strings,
fragments, oversized values, and non-identifier payloads. A route opens only
when its exact Thane identity is active; mismatches show both identities for
operator inspection without switching agents or disclosing destination data.

## Platform target

The deployment target remains iOS 26.0. Existing context providers continue to
work on iOS 26. Image Context Preview is guarded by iOS 27 availability and stays
out of the distribution build while its product value is evaluated. Requiring
an iOS 27 SDK to compile this preview does not raise the app's minimum OS.

## Build

Requires Xcode 27, its iOS 27 device and simulator SDKs, and
[just](https://github.com/casey/just).

```bash
just ci
```

`just toolchain` verifies the compiler and SDK versions before builds and
checks. `DEVELOPER_DIR` selects the toolchain and defaults to
`/Applications/Xcode.app/Contents/Developer`. The local test destination defaults
to the iOS 27.0 `iPhone 17 Pro` simulator; override it with
`IOS_SIMULATOR_DESTINATION` when using another installed simulator, including
an iOS 26 runtime for compatibility checks.

CI uses GitHub's `xcode-27` runner, explicitly selects Xcode 27.0 at
`/Applications/Xcode_27.0.app/Contents/Developer`, and tests with the preinstalled
iOS 27.0 `iPhone 18 Pro`. The current
[runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
lists that toolchain and simulator; GitHub currently describes this runner as
a public preview.

## App Store posture

- iOS sandbox with the standard `location` background mode solely for the
  separately enabled significant-change location and visit features.
- Public Apple frameworks only, including Core Location, PhotoKit, MapKit,
  Foundation, UIKit, Network, Security, and SwiftUI. The development-only image
  preview also uses PhotosUI and Foundation Models.
- Foreground-only realtime service plus best-effort significant-change
  background location and visit publication.
- Purpose strings for location, photo-library, and local-network access.
- A bundled privacy manifest covering app preferences and the data categories
  the app can transmit to the operator's configured Thane instance.

App Store Connect privacy answers and a privacy-policy URL still need to be
completed before submission. A production app icon and store metadata are also
release prerequisites.

## Near-term data-source roadmap

The provider boundary is ready for separately reviewed, independently
authorized integrations such as Calendar, Contacts, Reminders, HealthKit,
Motion & Fitness, HomeKit, and Focus status. Each should land as a
focused capability with bounded queries and clear field-level disclosure; they
should not be bundled behind a single broad consent switch.

The broader identity-first product arc is tracked in
[roadmap issue #8](https://github.com/nugget/thane-ios-companion/issues/8), including
the remaining notifications, inbox delivery, and conversation work. Conversation
transport and synchronized history remain server-owned future work under
[thane-ai-agent issue #1502](https://github.com/nugget/thane-ai-agent/issues/1502);
Signal remains the operator communication channel in the meantime.

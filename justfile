set quiet

app := "thane-ios-companion"

export DEVELOPER_DIR := env("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

default:
    @echo "Common workflows:"
    @echo "    just build    # build for a generic iOS device"
    @echo "    just build-release # build the App Store configuration"
    @echo "    just build-device # build signed Debug app for a physical device"
    @echo "    just devices  # list paired physical iPhones"
    @echo "    just deploy <device> # build, install, and launch on an explicit iPhone"
    @echo "    just test     # run Swift Testing on an iPhone simulator"
    @echo "    just toolchain # verify the Xcode 27 toolchain and SDKs"
    @echo "    just ci       # full local gate"

[doc("Verify the Xcode 27 compiler and iOS SDKs")]
toolchain:
    #!/usr/bin/env bash
    set -euo pipefail
    version="$(xcodebuild -version)"
    if [[ "$version" != Xcode\ 27.* ]]; then
        printf 'Xcode 27 is required. Set DEVELOPER_DIR to its Contents/Developer directory.\n' >&2
        exit 1
    fi
    printf '%s\n' "$version"
    for sdk in iphoneos iphonesimulator; do
        sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
        if [[ "$sdk_version" != 27.* ]]; then
            printf 'The %s SDK must be version 27; found %s.\n' "$sdk" "$sdk_version" >&2
            exit 1
        fi
        printf '%s SDK: %s\n' "$sdk" "$sdk_version"
    done

[doc("Build the app for a generic iOS device")]
build: toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild \
        -scheme "{{ app }}" \
        -destination 'generic/platform=iOS' \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        build

[doc("Build the release app for a generic iOS device")]
build-release: toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild \
        -scheme "{{ app }}" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        build

[doc("Build a signed Debug app using local development signing assets")]
build-device: toolchain
    bash scripts/deploy-ios.sh build

[doc("List physical iPhones without exposing hardware identifiers")]
devices:
    bash scripts/deploy-ios.sh devices

[doc("Build signed Debug, install in place, and launch on an explicit iPhone name or identifier")]
[positional-arguments]
deploy device: toolchain
    bash scripts/deploy-ios.sh deploy "$1"

[doc("Run unit tests on the latest configured iPhone simulator")]
test: toolchain
    #!/usr/bin/env bash
    set -euo pipefail
    destination="${IOS_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0}"
    xcodebuild \
        -scheme "{{ app }}" \
        -destination "$destination" \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        test

[doc("Run the full local validation gate")]
lint:
    plutil -lint thane-ios-companion/Info.plist
    plutil -lint thane-ios-companion/PrivacyInfo.xcprivacy
    plutil -lint thane-ios-companion.xcodeproj/project.pbxproj
    bash -n scripts/deploy-ios.sh
    git diff --check

[doc("Run the full local validation gate")]
ci: toolchain lint build build-release test

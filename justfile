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
    @echo "    just ci       # full local gate"

[doc("Build the app for a generic iOS device")]
build:
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
build-release:
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
build-device:
    bash scripts/deploy-ios.sh build

[doc("List physical iPhones without exposing hardware identifiers")]
devices:
    bash scripts/deploy-ios.sh devices

[doc("Build signed Debug, install in place, and launch on an explicit iPhone name or identifier")]
[positional-arguments]
deploy device:
    bash scripts/deploy-ios.sh deploy "$1"

[doc("Run unit tests on the latest configured iPhone simulator")]
test:
    #!/usr/bin/env bash
    set -euo pipefail
    destination="${IOS_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
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
ci: lint build build-release test

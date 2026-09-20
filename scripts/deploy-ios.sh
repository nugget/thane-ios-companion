#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="thane-ios-companion"
bundle_id="info.nugget.thane-ios-companion"
team_id="9KR5L363XM"
derived_data="${IOS_DEVICE_DERIVED_DATA_PATH:-$project_root/.build/ios-device}"
app_path="$derived_data/Build/Products/Debug-iphoneos/$app_name.app"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/thane-ios-deploy.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

list_devices() {
    xcrun devicectl --timeout 20 --quiet \
        --json-output "$temporary_directory/devices.json" list devices
    python3 - "$temporary_directory/devices.json" "$@" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1]))
phones = [device for device in document["result"]["devices"]
          if device["properties"]["hardware"].get("deviceType") == "iPhone"
          and device["properties"]["hardware"].get("reality") == "physical"]
if len(sys.argv) == 2:
    if not phones:
        print("No paired physical iPhones found. Connect and trust an iPhone first.")
    for device in phones:
        properties = device["properties"]
        print(" | ".join((properties["state"]["name"],
                          properties["hardware"]["marketingName"],
                          properties["software"]["osVersionNumber"]["stringValue"],
                          properties["connection"].get("state", "unknown"))))
else:
    selected = sys.argv[2]
    matches = [device for device in phones
               if selected in (device["properties"]["state"]["name"],
                               device["identifier"],
                               device["properties"]["hardware"].get("udid"))]
    if len(matches) != 1:
        sys.exit("Select exactly one physical iPhone by its full name or identifier; run just devices.")
    print(matches[0]["identifier"])
PY
}

check_device() {
    xcrun devicectl --timeout 20 --quiet \
        --json-output "$temporary_directory/details.json" \
        device info details --device "$device_id"
    python3 - "$temporary_directory/details.json" <<'PY'
import json
import sys

properties = json.load(open(sys.argv[1]))["result"]["properties"]
connection = properties["connection"]
if connection.get("state") == "unavailable":
    sys.exit("The selected iPhone is unavailable. Connect and unlock it, then retry just deploy.")
if connection.get("pairingState") != "paired":
    sys.exit("The selected iPhone must trust this Mac before deployment.")
if "enabled" not in properties["state"].get("developerModeStatus", {}):
    sys.exit("Enable Developer Mode on the selected iPhone before deployment.")
PY
    # Unlike cached device details, reading installed apps needs a live device.
    xcrun devicectl --timeout 20 --quiet \
        --json-output "$temporary_directory/installed-app.json" \
        device info apps --device "$device_id" --bundle-id "$bundle_id"
}

build_app() {
    xcodebuild \
        -project "$project_root/$app_name.xcodeproj" \
        -scheme "$app_name" \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        build
    codesign --verify --strict "$app_path"
    codesign -d --entitlements - --xml "$app_path" > "$temporary_directory/entitlements.plist"
    python3 - "$app_path/Info.plist" "$temporary_directory/entitlements.plist" "$bundle_id" "$team_id" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
with open(sys.argv[2], "rb") as stream:
    entitlements = plistlib.load(stream)
bundle, team = sys.argv[3:]
if info.get("CFBundleIdentifier") != bundle:
    sys.exit("The signed build has an unexpected bundle identifier; deployment stopped.")
if (entitlements.get("application-identifier") != f"{team}.{bundle}"
        or entitlements.get("com.apple.developer.team-identifier") != team
        or entitlements.get("get-task-allow") is not True):
    sys.exit("The build is not signed for the expected development team and app; deployment stopped.")
PY
    printf 'Signed Debug app: %s\n' "$app_path"
}

case "${1:-}" in
    devices)
        list_devices
        ;;
    build)
        build_app
        ;;
    deploy)
        if [[ $# -ne 2 || -z "$2" ]]; then
            printf 'Usage: just deploy <exact-device-name-or-identifier>\n' >&2
            exit 2
        fi
        device_id="$(list_devices "$2")"
        check_device
        build_app
        check_device
        # Installing the same bundle and signing identity updates it in place.
        xcrun devicectl --timeout 120 --quiet \
            --json-output "$temporary_directory/install.json" \
            device install app --device "$device_id" "$app_path"
        xcrun devicectl --timeout 30 --quiet \
            --json-output "$temporary_directory/launch.json" \
            device process launch --device "$device_id" "$bundle_id"
        printf 'Installed and launched %s on the selected iPhone.\n' "$app_name"
        ;;
    *)
        printf 'Use just devices, just build-device, or just deploy <device>.\n' >&2
        exit 2
        ;;
esac

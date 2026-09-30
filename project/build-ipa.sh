#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
team_id="${APPLE_TEAM_ID:-}"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "Xcode with the iPhoneOS SDK is required." >&2
    exit 1
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

build_args=(
    -project "$project_dir/ClassPulseTest.xcodeproj"
    -scheme ClassPulseTest
    -configuration Debug
    -destination 'generic/platform=iOS'
    -derivedDataPath "$build_dir/DerivedData"
)

if [[ -n "$team_id" ]]; then
    build_args+=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$team_id" CODE_SIGN_STYLE=Automatic)
else
    build_args+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${build_args[@]}" build

app_path="$build_dir/DerivedData/Build/Products/Debug-iphoneos/ClassPulseTest.app"
if [[ ! -d "$app_path" ]]; then
    echo "The app was not produced." >&2
    exit 1
fi

mkdir -p "$project_dir/dist"
mkdir "$build_dir/Payload"
cp -R "$app_path" "$build_dir/Payload/"
(
    cd "$build_dir"
    zip -qry "$project_dir/dist/ClassPulseTest.ipa" Payload
)

echo "$project_dir/dist/ClassPulseTest.ipa"

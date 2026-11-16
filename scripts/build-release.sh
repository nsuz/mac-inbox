#!/bin/zsh
# Builds a Release Inbox.app, wraps it in a .dmg and writes SHA256SUMS.txt into dist/.
#
#   SIGNING_IDENTITY  codesign identity (default "-": ad-hoc; use "Developer ID Application: …")
#   NOTARY_PROFILE    notarytool keychain profile; when set, the .dmg is notarized and stapled
set -euo pipefail

readonly root=${0:A:h:h}
readonly identity=${SIGNING_IDENTITY:--}
readonly dist=$root/dist
readonly derived=$dist/DerivedData
readonly staging=$dist/staging

rm -rf "$dist"
mkdir -p "$dist"

# The build action, unlike archive, injects get-task-allow, which lets any debugger attach and
# which notarization rejects. Automatic signing only knows ad-hoc here (no team in the project),
# so a Developer ID identity is applied manually with the team parsed from its "(TEAMID)"
# suffix, and with the secure timestamp the build action also omits.
signing=(CODE_SIGN_IDENTITY="$identity" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if [[ $identity =~ '\(([A-Z0-9]+)\)$' ]]; then
    signing+=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$match[1]" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

xcodebuild -project "$root/Inbox.xcodeproj" -scheme Inbox -configuration Release \
    -derivedDataPath "$derived" "${signing[@]}" -quiet build

readonly app=$derived/Build/Products/Release/Inbox.app
readonly version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
readonly dmg=$dist/Inbox-$version.dmg

codesign --verify --deep --strict "$app"
# Notarization accepts only apps signed with the hardened runtime.
if [[ $(codesign --display --verbose "$app" 2>&1) != *flags=*runtime* ]]; then
    echo "error: $app is not signed with the hardened runtime" >&2
    exit 1
fi
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Inbox -srcfolder "$staging" -ov -format UDZO -quiet "$dmg"
rm -rf "$staging"

if [[ $identity != "-" ]]; then
    codesign --sign "$identity" --timestamp "$dmg"
fi
if [[ -n ${NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
fi

(cd "$dist" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt)
rm -rf "$derived"
echo "built $dmg"
cat "$dist/SHA256SUMS.txt"

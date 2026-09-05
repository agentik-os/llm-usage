#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
app="$PWD/dist/QuotaBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/OpenAIQuotaBar "$app/Contents/MacOS/OpenAIQuotaBar"
mkdir -p "$app/Contents/Resources/Bridge"
cp Sources/OpenAIQuotaBar/Resources/quotabar_peer.py "$app/Contents/Resources/Bridge/quotabar_peer.py"
mkdir -p dist/QuotaBar-Connector
cp Sources/OpenAIQuotaBar/Resources/quotabar_peer.py dist/QuotaBar-Connector/quotabar-peer.py
cp Scripts/install-peer.sh dist/QuotaBar-Connector/install.sh
cp CONNECTOR.md dist/QuotaBar-Connector/README.md
cp LICENSE dist/QuotaBar-Connector/LICENSE
/usr/bin/ditto -c -k --keepParent dist/QuotaBar-Connector dist/QuotaBar-Connector.zip
/usr/libexec/PlistBuddy -c 'Clear dict' "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.openaiquotabar.app' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string QuotaBar' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string QuotaBar' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string OpenAIQuotaBar' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 4.0.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 8' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$app/Contents/Info.plist"
if [[ -f Assets/QuotaBar.icns ]]; then
    cp Assets/QuotaBar.icns "$app/Contents/Resources/QuotaBar.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string QuotaBar' "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
print "Built: $app"

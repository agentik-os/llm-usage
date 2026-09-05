#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
app="$PWD/dist/LLM Usage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/OpenAIQuotaBar "$app/Contents/MacOS/LLMUsage"
mkdir -p "$app/Contents/Resources/Bridge"
cp Sources/OpenAIQuotaBar/Resources/quotabar_peer.py "$app/Contents/Resources/Bridge/quotabar_peer.py"
mkdir -p dist/LLM-Usage-Connector
cp Sources/OpenAIQuotaBar/Resources/quotabar_peer.py dist/LLM-Usage-Connector/quotabar-peer.py
cp Scripts/install-peer.sh dist/LLM-Usage-Connector/install.sh
cp CONNECTOR.md dist/LLM-Usage-Connector/README.md
cp LICENSE dist/LLM-Usage-Connector/LICENSE
/usr/bin/ditto -c -k --keepParent dist/LLM-Usage-Connector dist/LLM-Usage-Connector.zip
/usr/libexec/PlistBuddy -c 'Clear dict' "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.openaiquotabar.app' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string LLM Usage' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string LLM Usage' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string LLMUsage' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 4.0.1' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 9' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$app/Contents/Info.plist"
if [[ -f Assets/QuotaBar.icns ]]; then
    cp Assets/QuotaBar.icns "$app/Contents/Resources/LLMUsage.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string LLMUsage' "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
print "Built: $app"

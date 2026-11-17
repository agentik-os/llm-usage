#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/LLM Usage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/OpenAIQuotaBar" "$app/Contents/MacOS/LLMUsage"
if [[ -d "$bin_dir/OpenAIQuotaBar_OpenAIQuotaBar.bundle" ]]; then
    ditto "$bin_dir/OpenAIQuotaBar_OpenAIQuotaBar.bundle" "$app/Contents/Resources/OpenAIQuotaBar_OpenAIQuotaBar.bundle"
fi
mkdir -p "$app/Contents/Resources/Bridge"
cp Sources/OpenAIQuotaBar/Resources/quotabar_peer.py "$app/Contents/Resources/Bridge/quotabar_peer.py"
cp Sources/OpenAIQuotaBar/Resources/hermes_pool_sync.py "$app/Contents/Resources/Bridge/hermes_pool_sync.py"
cp Sources/OpenAIQuotaBar/Resources/machine_monitor.py "$app/Contents/Resources/Bridge/machine_monitor.py"
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
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 4.10.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 27' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$app/Contents/Info.plist"
if [[ -f Assets/QuotaBar.icns ]]; then
    cp Assets/QuotaBar.icns "$app/Contents/Resources/LLMUsage.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string LLMUsage' "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
print "Built: $app"

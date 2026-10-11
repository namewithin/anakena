#!/bin/bash
# Builds build/Anakena.app. Set SIGN_ID to a real signing identity to keep the
# Accessibility permission across rebuilds (ad-hoc "-" signing loses it each time).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Anakena"

APP=build/Anakena.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Anakena"

# App icon (.icns from the 1024px master) and the menu bar template images.
mkdir -p "$APP/Contents/Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" Assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" Assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Assets/StatusIcon.png Assets/StatusIcon@2x.png "$APP/Contents/Resources/"
cp -R Localization/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.leo.anakena</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>Anakena</string>
    <key>CFBundleExecutable</key>
    <string>Anakena</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Anakena watches keystrokes on this Mac to fix words typed in the wrong keyboard layout. Nothing is sent anywhere; learned words are kept only on this Mac.</string>
</dict>
</plist>
PLIST

if [ -z "${SIGN_ID:-}" ]; then
    IDS="$(security find-identity -p codesigning 2>/dev/null || true)"
    MATCHES="$(awk '/"Anakena Local Signing"/ && length($2) == 40 && $2 !~ /[^[:xdigit:]]/ { print $2 }' <<<"$IDS" | sort -u)"
    COUNT="$(awk 'NF { n++ } END { print n+0 }' <<<"$MATCHES")"
    if [ "$COUNT" -gt 1 ]; then
        echo 'error: multiple "Anakena Local Signing" identities; remove duplicates or set SIGN_ID to the intended SHA-1 hash' >&2
        exit 1
    elif [ "$COUNT" -eq 1 ]; then
        SIGN_ID="$MATCHES"
    else
        SIGN_ID="-"
    fi
fi
if [ "$SIGN_ID" = "-" ]; then
    echo "warning: ad-hoc signing; Accessibility must be re-granted after each rebuild (run scripts/make-cert.sh once to fix)" >&2
fi

codesign --force --deep --options runtime -s "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
codesign -d -r- "$APP"
echo "Built $APP"

#!/bin/zsh
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_APP="$PROJECT_DIR/纸页文献库.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zhiye-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
BUILD_DIR="$STAGING_DIR/纸页文献库.app"
CACHE_DIR="${TMPDIR:-/tmp}/zhiye-swift-cache"
mkdir -p "$BUILD_DIR/Contents/MacOS" "$BUILD_DIR/Contents/Resources" "$CACHE_DIR"
xcrun swiftc -swift-version 5 -O -module-cache-path "$CACHE_DIR" \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework SwiftUI -framework PDFKit -framework AppKit -framework CryptoKit \
  "$PROJECT_DIR"/Sources/*.swift -o "$BUILD_DIR/Contents/MacOS/Zhiye"
cat > "$BUILD_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Zhiye</string>
<key>CFBundleIdentifier</key><string>local.zhiye.library</string>
<key>CFBundleName</key><string>纸页文献库</string>
<key>CFBundleDisplayName</key><string>纸页文献库</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>纸页文献库 · 本地 PDF 管理</string>
</dict></plist>
PLIST
codesign --force --sign - "$BUILD_DIR"
ditto "$BUILD_DIR" "$OUTPUT_APP"
echo "已生成：$OUTPUT_APP"

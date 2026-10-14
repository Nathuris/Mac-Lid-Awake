#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
version=1.0.1
output="$(mktemp -d "$PWD/发布-$version-XXXXXXXX")"
app="$output/合盖不休眠.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$output/AppIcon.iconset"
xcrun swiftc -module-cache-path "$output/编译缓存" -swift-version 5 -O -target arm64-apple-macos14.0 Sources/main.swift -framework AppKit -framework IOKit -o "$app/Contents/MacOS/LidAwake"
xcrun swiftc -module-cache-path "$output/编译缓存" Scripts/绘制图标.swift -framework AppKit -o "$output/绘制图标"
"$output/绘制图标" "$output/AppIcon.iconset"
iconutil -c icns "$output/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp Resources/恢复守护.sh "$app/Contents/Resources/恢复守护.sh"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LidAwake</string>
<key>CFBundleIdentifier</key><string>com.nathuris.lidawake.prototype</string>
<key>CFBundleName</key><string>合盖不休眠</string>
<key>CFBundleDisplayName</key><string>合盖不休眠</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>101</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$output/安装盘"
ditto "$app" "$output/安装盘/合盖不休眠.app"
ln -s /Applications "$output/安装盘/Applications"
cp docs/安装说明-1.0.1.txt "$output/安装盘/安装说明.txt"
hdiutil create -volname "合盖不休眠 $version" -srcfolder "$output/安装盘" -format UDZO -ov "$output/Mac-Lid-Awake-$version-arm64.dmg"
hdiutil verify "$output/Mac-Lid-Awake-$version-arm64.dmg"
(cd "$output" && shasum -a 256 "Mac-Lid-Awake-$version-arm64.dmg" > SHA256SUMS.txt)
print -r -- "发布目录：$output"

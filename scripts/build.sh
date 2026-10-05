#!/bin/zsh
set -eu
cd "${0:A:h:h}"
build_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
swift build --build-system native --scratch-path .build-v0.4 --sdk "$build_sdk_path" -c release --product AirDropDrawer
binary_directory=$(swift build --build-system native --scratch-path .build-v0.4 --sdk "$build_sdk_path" -c release --show-bin-path)
application_path="$PWD/dist/AirDrop Drawer.app"
mkdir -p "$application_path/Contents/MacOS" "$application_path/Contents/Resources"
cp "$binary_directory/AirDropDrawer" "$application_path/Contents/MacOS/AirDropDrawer"
cat > "$application_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AirDropDrawer</string>
<key>CFBundleIdentifier</key><string>local.chengzi.AirDropDrawer</string>
<key>CFBundleName</key><string>AirDrop Drawer</string>
<key>CFBundleDisplayName</key><string>AirDrop 抽屉</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSDesktopFolderUsageDescription</key><string>读取你拖入的桌面文件或文件夹，以暂存引用、拖出使用或通过隔空投送发送。</string>
<key>NSDocumentsFolderUsageDescription</key><string>读取你拖入的文稿文件或文件夹，以暂存引用、拖出使用或通过隔空投送发送。</string>
<key>NSDownloadsFolderUsageDescription</key><string>读取你拖入的下载文件或文件夹，以暂存引用、拖出使用或通过隔空投送发送。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp Resources/AppIcon.icns "$application_path/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$application_path"
codesign --verify --strict "$application_path"
print -r -- "$application_path"

#!/bin/zsh
# Build a universal (Apple Silicon + Intel) Release of Verbatim and wrap it in
# a drag-to-install DMG: build/Verbatim-<version>.dmg
# The version comes from CFBundleShortVersionString in project.yml (Info.plist is generated from it).
set -euo pipefail
cd "$(dirname "$0")/.."

DD="${VERBATIM_DERIVED_DATA:-$HOME/Library/Developer/VerbatimDerivedData}"

if command -v xcodegen >/dev/null; then
    xcodegen generate --quiet
elif [[ ! -d Verbatim.xcodeproj ]]; then
    echo "Verbatim.xcodeproj is generated from project.yml: install XcodeGen (brew install xcodegen)." >&2
    exit 1
fi

xcodebuild -project Verbatim.xcodeproj -scheme Verbatim -configuration Release \
    -derivedDataPath "$DD" -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

APP="$DD/Build/Products/Release/Verbatim.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE:?}"' EXIT
ditto "$APP" "$STAGE/Verbatim.app"
ln -s /Applications "$STAGE/Applications"
# The app is ad-hoc signed (no Apple Developer ID), so macOS blocks the first launch.
cat > "$STAGE/打不开时看这里.txt" <<'EOF'
安装：把 Verbatim 拖到旁边的 Applications 文件夹。

第一次打开时，macOS 会提示无法验证开发者（这个 App 没有 Apple 开发者签名）：
1. 先点「完成」关掉提示。
2. 打开「系统设置 → 隐私与安全性」，拉到最下面，点 Verbatim 旁边的「仍要打开」，输入电脑密码确认。
3. 之后就能正常打开了，只需要做这一次。

也可以在「终端」里运行这一行，效果一样：
xattr -dr com.apple.quarantine /Applications/Verbatim.app

需要 macOS 26 或更新版本。
EOF

mkdir -p build
DMG="build/Verbatim-$VERSION.dmg"
hdiutil create -volname "Verbatim $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
echo "$DMG"

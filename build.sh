#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app="$build_dir/Codex Traffic Light.app"
contents="$app/Contents"
binary="$contents/MacOS/CodexTrafficLight"

rm -rf "$app"
mkdir -p "$contents/MacOS"

swiftc -O \
  -target "$(uname -m)-apple-macosx13.0" \
  "$project_dir/CodexTrafficLight.swift" \
  -o "$binary" \
  -framework AppKit \
  -framework Combine \
  -framework SwiftUI \
  -lsqlite3

plutil -create xml1 "$contents/Info.plist"
plutil -insert CFBundleDevelopmentRegion -string zh_CN "$contents/Info.plist"
plutil -insert CFBundleExecutable -string CodexTrafficLight "$contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.newton.codex-traffic-light "$contents/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$contents/Info.plist"
plutil -insert CFBundleName -string "Codex Traffic Light" "$contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 1.1.0 "$contents/Info.plist"
plutil -insert CFBundleVersion -string 2 "$contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$contents/Info.plist"
plutil -insert LSUIElement -bool true "$contents/Info.plist"
plutil -insert NSHighResolutionCapable -bool true "$contents/Info.plist"

codesign --force --sign - "$app"
"$binary" --self-test
print "Built: $app"

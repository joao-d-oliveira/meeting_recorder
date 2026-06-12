#!/bin/bash
# Builds MeetingRecorder.app into build/. Ad-hoc signed so macOS TCC
# (microphone permission) gets a stable identity to attach to.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/MeetingRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetingRecorder "$APP/Contents/MacOS/MeetingRecorder"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MeetingRecorder</string>
    <key>CFBundleIdentifier</key>
    <string>com.joao.meeting-recorder</string>
    <key>CFBundleName</key>
    <string>Meeting Recorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Meeting Recorder captures your microphone and system audio to record meetings locally.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

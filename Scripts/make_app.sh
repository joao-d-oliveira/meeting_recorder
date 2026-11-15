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

# The transcription pipeline (run.sh + python), found at runtime via Bundle.main.resourceURL.
# -p keeps the executable bits, -X leaves extended attributes out (codesign rejects some).
# tests/ is dev-only.
mkdir -p "$APP/Contents/Resources"
cp -RpX Pipeline "$APP/Contents/Resources/Pipeline"
rm -rf "$APP/Contents/Resources/Pipeline/tests"
find "$APP/Contents/Resources/Pipeline" -name __pycache__ -prune -exec rm -rf {} +
for script in run.sh setup.sh; do
    [ -x "$APP/Contents/Resources/Pipeline/$script" ] \
        || { echo "error: Pipeline/$script is not executable in the bundle" >&2; exit 1; }
done

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

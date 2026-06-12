# Meeting Recorder

Native macOS app that records meeting audio locally by mixing a remote/system
audio source (e.g. BlackHole 2ch) with your microphone via ffmpeg.

## Requirements

- macOS 14+
- ffmpeg (`brew install ffmpeg`)
- A loopback audio device such as [BlackHole](https://github.com/ExistentialAudio/BlackHole)
  receiving the meeting audio (e.g. via a Multi-Output Device)

## Build & run

```bash
./Scripts/make_app.sh
open build/MeetingRecorder.app
```

## Development

```bash
swift build                   # compile
swift run RecorderCoreTests   # run the test suite
swift run MeetingRecorder     # run the app unbundled (no mic permission prompt)
```

Recordings default to `~/Documents/Recordings/meetings/<timestamp>/meeting.flac`.

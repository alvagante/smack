# Release video

One short video per release: a screen recording cut into captioned, sped-up segments, with a Suno song underneath.

Needs `ffmpeg` (brew) and Pillow (`pip3 install pillow`). Dev tooling only; nothing here ships in the app.

## Per release

1. Record a walkthrough of the new version (any length; 1.1.0 was 4:37 at 2704x1756, silent is fine).
2. Run `/release-video <version> <recording.mov>` in Claude Code. It writes `<version>/segments.json` and `<version>/suno.md` (style prompt and lyrics).
3. Generate the song in Suno from `suno.md`, download the mp3 (about 80 s).
4. Run `/release-video <version> <recording.mov> <song.mp3>`, or by hand:

```bash
python3 Scripts/release-video/release-video.py render docs/development/release-video/<version>/segments.json <recording.mov> ~/Desktop/Smack-<version>-release.mp4 --song <song.mp3>
```

Segment speeds are scaled so the video matches the song length (4 s title card and 5 s outro included). Tweak `weight` per segment to slow down or speed up one screen, then rerun; rendering takes under a minute.

`python3 Scripts/release-video/release-video.py sheet <recording.mov> <dir>` makes a labelled contact sheet (one frame per 10 s) to pick segment times from.

Suno has no official API, so the song step stays manual. Archive per release: `segments.json` and `suno.md` (no media in the repo).

## Vertical (Shorts, Reels, TikTok)

Add `--vertical` to `render` for 1080x1920. Each segment is a 4:5 crop of the recording over a blurred copy, with the caption below. Set a top-level `"focus": [x, y]` (fractions of the frame, default `[0.5, 0.5]`) in `segments.json` to move the crop, or per segment `"focus"`, `"zoom"` and `"fit": true` (whole frame). Same song, same length.

---
description: Prepare the release video for a Smack version (lyrics, Suno brief, segment plan), then render it
argument-hint: <version> <recording.mov> [song.mp3]
---

Produce the release video for Smack $1 from the screen recording `$2`. The tool is `Scripts/release-video/release-video.py` (see `docs/development/release-video/README.md`). Work in `docs/development/release-video/$1/`.

1. Read the `## [$1]` section of `CHANGELOG.md`. Pick the 4 to 6 headline user-visible features.
2. Run `python3 Scripts/release-video/release-video.py sheet "$2" <scratchpad>/sheet`, read `sheet.jpg` (one frame per 10 s, labelled), and note which screens show which feature.
3. Write `segments.json` (format in the script's docstring): 8 to 12 segments, about 10 to 30 s of source each, covering the headline features first. Use `weight` as relative speed: below 1 for screens worth reading, above 1 for scrolling or filler. Captions are short and name the feature.
4. If no song was given ($3 empty): write `suno.md` with a title, a style prompt under 200 characters (upbeat synth-pop, 120 BPM, short, about 80 s, English), and lyrics with `[Verse]`/`[Chorus]` tags about this release's headline features. About 16 to 24 sung lines for 80 s. Then stop and tell the user to generate it in Suno and rerun with the mp3. Do not invent a song file.
5. If a song was given: render with `--song`. Output goes to `~/Desktop/Smack-$1-release.mp4`; speeds auto-fit the song length. Report the duration and any warning.

Rules: no em or en dashes in captions or lyrics; commit nothing; log the render command in the command log.

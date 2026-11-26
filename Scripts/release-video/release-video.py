#!/usr/bin/env python3
"""Release video tooling for Smack.

  release-video.py sheet  RECORDING OUTDIR          contact sheet (one frame per 10 s, labelled)
  release-video.py render SEGMENTS.json RECORDING OUT.mp4 [--song SONG.mp3] [--vertical]

Needs ffmpeg, ffprobe and Pillow (pip3 install pillow). Dev tool only, not part of the app.

SEGMENTS.json:
  {"version": "1.1.0",
   "tagline": "A tiny menu-bar monitor for your Mac",
   "features": "Projects  ·  Session Timeline  ·  Live Summary",
   "outro": ["brew install alvagante/tap/smack", "github.com/alvagante/smack"],
   "segments": [{"start": 0, "length": 10, "caption": "Live Summary tiles", "weight": 1}]}

With --song, segment speeds are scaled so the video is exactly as long as the song
(title 4 s + outro 5 s included). "weight" is a relative speed (default 1): a segment
with weight 2 plays twice as fast as one with weight 1. Without a song, the speed
is the weight times 3.

--vertical renders 1080x1920 (Shorts, Reels, TikTok). Each segment shows a 4:5 crop of the
recording, over a blurred copy of itself, around "focus": [x, y] (fractions of the frame,
default top-level "focus", else [0.5, 0.5]); "zoom" (default 1) crops tighter. "fit": true shows the whole frame over a blurred copy of
itself instead of cropping, for screens where the full width matters.
"""
import argparse, json, pathlib, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

W, H, BG = 1920, 1080, (11, 15, 26)
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG = "/System/Library/Fonts/Supplemental/Arial.ttf"
TITLE_S, OUTRO_S = 4.0, 5.0


def ff(*a):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *a], check=True)


def duration(path):
    return float(subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)]))


def font(p, s):
    return ImageFont.truetype(p, s)


def card(tmp, name, lines):
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    for y in range(H):
        c = int(40 * y / H)
        d.line([(0, y), (W, y)], fill=(BG[0] + c // 2, BG[1] + c // 2, BG[2] + c))
    sc = 1.0 if W > H else 0.75
    rows = []
    for text, size, col, f in lines:
        ft = font(f, int(size * sc))
        for part in (text.split("  ·  ") if W < H else [text]):
            rows.append((part, ft, col))
    y = (H - sum(int(r[1].size * 1.5) for r in rows)) // 2
    for text, ft, col in rows:
        d.text(((W - d.textlength(text, font=ft)) / 2, y), text, font=ft, fill=col)
        y += int(ft.size * 1.5)
    p = tmp / f"{name}.png"
    im.save(p)
    return p


def caption(tmp, i, text):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if W > H:
        ft = font(BOLD, 44)
        w = d.textlength(text, font=ft)
        x, y = 70, H - 130
        d.rounded_rectangle([x - 28, y - 18, x + w + 28, y + 70], 24, fill=(11, 15, 26, 220))
        d.text((x, y), text, font=ft, fill=(255, 255, 255, 255))
    else:
        ft = font(BOLD, 58)
        lines, cur = [], ""
        for word in text.split():
            if cur and d.textlength(cur + " " + word, font=ft) > W - 160:
                lines.append(cur); cur = word
            else:
                cur = (cur + " " + word).strip()
        lines.append(cur)
        lh = 76
        top = H - 380 - lh * len(lines)
        wmax = max(d.textlength(l, font=ft) for l in lines)
        d.rounded_rectangle([(W - wmax) / 2 - 32, top - 20, (W + wmax) / 2 + 32, top + lh * len(lines) + 4], 28,
                            fill=(11, 15, 26, 225))
        for n, l in enumerate(lines):
            d.text(((W - d.textlength(l, font=ft)) / 2, top + n * lh), l, font=ft, fill=(255, 255, 255, 255))
    p = tmp / f"cap{i}.png"
    im.save(p)
    return p


def sheet(recording, outdir):
    out = pathlib.Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    ff("-i", recording, "-vf", "fps=1/10,scale=640:-1", str(out / "f%03d.jpg"))
    frames = sorted(out.glob("f*.jpg"))
    cols = 4
    fw, fh = Image.open(frames[0]).size
    rows = (len(frames) + cols - 1) // cols
    im = Image.new("RGB", (cols * fw, rows * fh), BG)
    d = ImageDraw.Draw(im)
    for n, f in enumerate(frames):
        x, y = (n % cols) * fw, (n // cols) * fh
        im.paste(Image.open(f), (x, y))
        d.rectangle([x, y, x + 90, y + 30], fill=(0, 0, 0))
        d.text((x + 6, y + 6), f"{n * 10}s", font=font(BOLD, 20), fill=(255, 255, 0))
        f.unlink()
    p = out / "sheet.jpg"
    im.save(p, quality=85)
    print(f"{p}  ({duration(recording):.0f} s recording, {len(frames)} frames, one per 10 s)")


def render(segfile, recording, out, song, vertical=False):
    global W, H
    if vertical:
        W, H = 1080, 1920
    cfg = json.loads(pathlib.Path(segfile).read_text())
    segs = cfg["segments"]
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="smackvid-"))
    total_src = sum(s["length"] / s.get("weight", 1) for s in segs)
    if song:
        avail = duration(song) - TITLE_S - OUTRO_S
        k = total_src / avail
        if k < 1:
            print(f"warning: song is long for these segments; speeds would drop below 1x (k={k:.2f}). "
                  "Add segments or the video will be shorter than the song.", file=sys.stderr)
    else:
        k = 3.0
    clips = []

    c = tmp / "title.mp4"
    ff("-loop", "1", "-t", str(TITLE_S), "-i", str(card(tmp, "title", [
        (f"Smack {cfg['version']}", 150, (255, 255, 255), BOLD),
        (cfg.get("tagline", ""), 52, (170, 190, 230), REG),
        (cfg.get("features", ""), 40, (120, 150, 210), REG)])),
       "-vf", "fps=30,fade=t=in:d=0.6,fade=t=out:st=3.4:d=0.6,format=yuv420p", "-c:v", "libx264", "-crf", "16", str(c))
    clips.append(c)

    for i, s in enumerate(segs):
        speed = max(1.0, s.get("weight", 1) * k) if song else s.get("weight", 1) * k
        o = s["length"] / speed
        c = tmp / f"c{i}.mp4"
        if not vertical:
            base = (f"[0:v]setpts=PTS/{speed:.5f},fps=30,scale={W}:{H}:force_original_aspect_ratio=decrease,"
                    f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=0x0b0f1a[b];")
        elif s.get("fit"):
            base = (f"[0:v]setpts=PTS/{speed:.5f},fps=30,split[a][f];"
                    f"[a]scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},boxblur=40,eq=brightness=-0.25[bg];"
                    f"[f]scale={W}:-2[fg];[bg][fg]overlay=0:40[b];")
        else:
            fx, fy = s.get("focus", cfg.get("focus", [0.5, 0.5]))
            z = s.get("zoom", 1.0)
            ch = f"ih/{z}"
            cw = f"{ch}*4/5"
            base = (f"[0:v]setpts=PTS/{speed:.5f},fps=30,split[a][f];"
                    f"[a]scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},boxblur=40,eq=brightness=-0.25[bg];"
                    f"[f]crop=w={cw}:h={ch}:x='max(0,min(iw-ow,{fx}*iw-ow/2))':y='max(0,min(ih-oh,{fy}*ih-oh/2))',"
                    f"scale={W}:-2[fg];[bg][fg]overlay=0:40[b];")
        fc = (base +
              f"[1:v]format=rgba,fade=t=in:st=0.3:d=0.4:alpha=1,fade=t=out:st={max(0.5, min(3.4, o - 0.6)):.2f}:d=0.4:alpha=1[c];"
              f"[b][c]overlay=0:0:shortest=1,fade=t=in:d=0.25,fade=t=out:st={o - 0.25:.2f}:d=0.25,format=yuv420p")
        ff("-ss", str(s["start"]), "-t", str(s["length"]), "-i", recording,
           "-loop", "1", "-i", str(caption(tmp, i, s["caption"])), "-filter_complex", fc,
           "-t", f"{o:.3f}", "-an", "-c:v", "libx264", "-crf", "18", str(c))
        clips.append(c)

    outro = cfg.get("outro", ["brew install alvagante/tap/smack", "github.com/alvagante/smack"])
    c = tmp / "outro.mp4"
    ff("-loop", "1", "-t", str(OUTRO_S), "-i", str(card(tmp, "outro", [
        (f"Smack {cfg['version']}", 120, (255, 255, 255), BOLD),
        (outro[0], 56, (140, 220, 170), REG),
        (outro[1] if len(outro) > 1 else "", 40, (120, 150, 210), REG)])),
       "-vf", "fps=30,fade=t=in:d=0.5,fade=t=out:st=4.2:d=0.8,format=yuv420p", "-c:v", "libx264", "-crf", "16", str(c))
    clips.append(c)

    lst = tmp / "list.txt"
    lst.write_text("".join(f"file '{c}'\n" for c in clips))
    silent = tmp / "silent.mp4"
    ff("-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", str(silent))
    if song:
        dur = duration(silent)
        ff("-i", str(silent), "-i", song, "-t", f"{dur:.2f}", "-map", "0:v", "-map", "1:a",
           "-af", f"afade=t=in:d=1,afade=t=out:st={dur - 3:.2f}:d=3", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", out)
    else:
        ff("-i", str(silent), "-c", "copy", out)
    print(f"{out}  ({duration(out):.1f} s)")


ap = argparse.ArgumentParser()
sub = ap.add_subparsers(dest="cmd", required=True)
a = sub.add_parser("sheet"); a.add_argument("recording"); a.add_argument("outdir")
b = sub.add_parser("render"); b.add_argument("segments"); b.add_argument("recording"); b.add_argument("out")
b.add_argument("--song")
b.add_argument("--vertical", action="store_true")
n = ap.parse_args()
sheet(n.recording, n.outdir) if n.cmd == "sheet" else render(n.segments, n.recording, n.out, n.song, n.vertical)

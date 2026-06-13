---
name: deviantart.com
description: "download videos from deviation pages (single/multi-file) given a /*/art/* URL."
argument-hint: <deviantart.com deviation URL> [destination directory]
---

## How it works

DeviantArt video deviations embed direct MP4 URLs inside the rendered DOM. A headless browser dump per file is sufficient — no API key, no login required for public deviations.

Multi-file deviations use `?file=N` URL parameters (e.g. `?file=2` through `?file=44`). The base URL (no parameter) is always the first file. Out-of-bounds `?file=` values return a page whose wixmp MP4 URLs are all already present in previously fetched pages — that is the stop condition.

## Step 0 — Detect single vs multi-file

Strip any `?file=` from the user's URL to get the canonical base URL. Fetch `?file=2`:

```bash
not-google-chrome -t 30 "BASE_URL?file=2" > /tmp/da_file.html
grep -oE 'https://wixmp[^"'\'']+\.mp4[^"'\'']*' /tmp/da_file.html | sort -u
```

If this returns an MP4 URL that differs from the base URL's MP4, it is multi-file. If the same URL appears (or the page is empty), it is single-file: download only the base URL.

## Single-file download

```bash
not-google-chrome -t 30 "BASE_URL" > /tmp/da_file.html
MP4=$(grep -oE 'https://wixmp[^"'\'']+\.mp4[^"'\'']*' /tmp/da_file.html | sort -u | head -1)
wget -q --show-progress -O "DEST/SLUG.mp4" "$MP4"
```

## Multi-file download loop

Maintain a set of already-downloaded wixmp URLs. For each page, extract wixmp URLs (`https://wixmp...mp4`), find ones not yet seen, download them. Stop when a page yields no new URLs — that means we have gone past the last valid file.

```python
import re, subprocess, os

WRAPPER = os.path.expanduser("~/.claude/skills/headless-browser/not-google-chrome")

def dump_dom(url):
    return subprocess.run(
        [WRAPPER, "-t", "30", url],
        capture_output=True, check=True, text=True
    ).stdout

def extract_wixmp_mp4s(html):
    return set(re.findall(r'https://wixmp[^"\x27]+\.mp4[^"\x27]*', html))

base_url = "BASE_URL"   # no ?file= suffix
dest = "DEST_DIR"
slug = base_url.rstrip("/").split("/")[-1]

seen = set()

# File 1: base URL
html = dump_dom(base_url)
urls = extract_wixmp_mp4s(html) - seen
if urls:
    url = next(iter(urls))
    subprocess.run(["wget", "-q", "--show-progress", "-O", f"{dest}/{slug}_file1.mp4", url])
    seen |= urls

# Files 2+
n = 2
while True:
    html = dump_dom(f"{base_url}?file={n}")
    urls = extract_wixmp_mp4s(html) - seen
    if not urls:
        break   # out-of-bounds page — all MP4s already seen
    url = next(iter(urls))
    subprocess.run(["wget", "-q", "--show-progress", "-O", f"{dest}/{slug}_file{n}.mp4", url])
    seen |= urls
    n += 1
```

In practice, write this as a shell loop or a short Python script, whichever is cleaner for the given task.

## Filename convention

- Single file: `SLUG.mp4`
- Multi-file: `SLUG_file1.mp4`, `SLUG_file2.mp4`, ..., `SLUG_fileN.mp4`

where SLUG is the last path segment of the deviation URL (e.g. `Interrogation-2-Abdominal-Pressure-1325618104`).

## What this skill does NOT do

- It does not handle image or literature deviations — only video.
- It does not handle deviations behind a login wall. If the dump returns a login page, the user must be logged in via the user-data-dir that `not-google-chrome` targets.
- It does not search DeviantArt or browse galleries.

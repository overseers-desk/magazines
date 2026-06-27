#!/usr/bin/env python3
"""PreToolUse hook: deny WebFetch against hosts it cannot read.

WebFetch converts static HTML to markdown. YouTube and Reddit serve a
client-rendered shell: the data lives in JavaScript, so WebFetch returns
only nav/footer chrome, and the connection often streams slowly with no
socket timeout, so the fetch can hang for minutes before yielding that
useless chrome (observed: a YouTube channel WebFetch ran 631s).

This hook matches WebFetch, inspects the URL host, and on a known-bad host
denies the call with a message pointing at a tool that works: yt-dlp when
the host has it (YouTube metadata), otherwise the serialised-browsing skill,
which drives a real logged-in browser and renders the JS.

Any host not on the list, or any malformed input, is allowed through
(emit nothing, exit 0) — the hook only fences the cases it knows fail.
"""

import json
import shutil
import sys
from urllib.parse import urlparse

# host suffix -> which kind of guidance to give
YOUTUBE = ("youtube.com", "youtu.be", "youtube-nocookie.com")
REDDIT = ("reddit.com", "redd.it")


def host_matches(host, suffixes):
    host = host.lower()
    return any(host == s or host.endswith("." + s) for s in suffixes)


def youtube_reason():
    parts = [
        "WebFetch can't read YouTube: the page is client-rendered, so it "
        "returns only nav/footer chrome, and the connection often hangs for "
        "minutes (no socket timeout)."
    ]
    if shutil.which("yt-dlp"):
        parts.append(
            "This host has yt-dlp — for channel/video metadata prefer: "
            "`yt-dlp -J --flat-playlist --socket-timeout 10 \"<url>\"` "
            "(the --socket-timeout is what stops it hanging)."
        )
    else:
        parts.append(
            "yt-dlp is not on this host; prefer the serialised-browsing skill "
            "to render the page."
        )
    parts.append(
        "For page text, captions, or anything yt-dlp's JSON omits, use the "
        "serialised-browsing skill."
    )
    return " ".join(parts)


def reddit_reason():
    return (
        "WebFetch can't reliably read Reddit: it hits interstitials/blocks or "
        "returns only chrome. Prefer the reddit skill (ot:reddit-com) for "
        "posts, comment trees, and search, or the serialised-browsing skill "
        "for an arbitrary page."
    )


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if data.get("tool_name") != "WebFetch":
        sys.exit(0)

    url = (data.get("tool_input") or {}).get("url", "")
    host = urlparse(url).hostname or ""
    if not host:
        sys.exit(0)

    if host_matches(host, YOUTUBE):
        deny(youtube_reason())
    if host_matches(host, REDDIT):
        deny(reddit_reason())

    sys.exit(0)


if __name__ == "__main__":
    main()

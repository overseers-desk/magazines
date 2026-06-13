#!/usr/bin/env python3
"""
Audit Instagram tag reshares for a brand account.

Use case: SOP D40 requires service team to reshare customer-tagged stories
immediately. This script audits compliance by checking which tags since a
given date were not reshared to the target's own story.

Pipeline:
  1. Resolve target user_id.
  2. Verify logged-in identity (some data is target-account only).
  3. Pull feed posts where target is tagged since --since (permanent).
  4. Pull activity-inbox story-mention notifications (retention limited).
  5. Pull target's currently-live story tray (<24h).
  6. If logged in as target, pull own story archive since --since.
  7. Cross-reference each tag against own stories; report unreshared items.

Data-window reality:
  - Tagged feed posts: full coverage since --since.
  - Story tag notifications: Instagram retains roughly the last 14-30 days
    in the activity inbox. Anything older is unrecoverable.
  - Customer-side stories: gone 24h after posting regardless.
  - Own story archive: only readable when logged in AS the target account.

Usage:
    not-google-chrome --cdp -- python3 audit-tag-reshares.py audit <handle> --since YYYY-MM-DD [--debug]

In --debug mode, raw API JSON for each step is saved to /tmp/instagram-audit-*.json
so reshare-match heuristics can be tuned against real data on first run.
"""

import argparse
import base64
import json
import os
import socket
import struct
import sys
import time
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Hand-rolled WebSocket over stdlib socket (copied verbatim from
# fetch-recent-posts.py per the BROWSER.md convention that CDP scripts each
# carry their own self-contained helpers).
# ---------------------------------------------------------------------------

def _ws_connect(url, timeout=20):
    url = url[len("ws://"):]
    host_port, path = (url.split("/", 1) + [""])[:2]
    host, port = host_port.rsplit(":", 1)
    sock = socket.create_connection((host, int(port)), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        f"GET /{path} HTTP/1.1\r\nHost: {host}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(4096)
    if b"101" not in resp:
        raise OSError(f"WebSocket handshake failed: {resp[:120]}")
    return sock


def _ws_send(sock, data):
    if isinstance(data, str):
        data = data.encode()
    n, mask = len(data), os.urandom(4)
    hdr = bytes([0x81])
    if n <= 125:      hdr += bytes([0x80 | n])
    elif n <= 0xFFFF: hdr += bytes([0xFE]) + struct.pack(">H", n)
    else:             hdr += bytes([0xFF]) + struct.pack(">Q", n)
    sock.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def _ws_recvn(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("WebSocket connection lost")
        buf += chunk
    return bytes(buf)


def _ws_recv(sock):
    b0, b1 = _ws_recvn(sock, 2)
    n = b1 & 0x7F
    if n == 126: n = struct.unpack(">H", _ws_recvn(sock, 2))[0]
    elif n == 127: n = struct.unpack(">Q", _ws_recvn(sock, 8))[0]
    mask = _ws_recvn(sock, 4) if b1 & 0x80 else None
    payload = _ws_recvn(sock, n)
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if b0 & 0x0F == 0x8:
        raise OSError("WebSocket closed by server")
    return payload.decode()


def _ws_close(sock):
    try:
        sock.sendall(bytes([0x88, 0x80]) + os.urandom(4))
    except Exception:
        pass
    sock.close()


def send_cdp(ws, method, params=None, counter=[0]):
    counter[0] += 1
    mid = counter[0]
    msg = {"id": mid, "method": method}
    if params:
        msg["params"] = params
    _ws_send(ws, json.dumps(msg))
    deadline = time.time() + 30
    while time.time() < deadline:
        resp = json.loads(_ws_recv(ws))
        if resp.get("id") == mid:
            return resp
    return None


def eval_js(ws, expression):
    result = send_cdp(ws, "Runtime.evaluate", {
        "expression": expression,
        "awaitPromise": True,
        "returnByValue": True,
    })
    val = result.get("result", {}).get("result", {}).get("value")
    exc = result.get("result", {}).get("exceptionDetails")
    if exc:
        return {"error": exc.get("text", "JS exception")}
    if val is None:
        return {"error": "No value returned from JS"}
    try:
        return json.loads(val)
    except json.JSONDecodeError:
        return {"raw": val}


def navigate_and_wait(ws, url, wait_seconds=5):
    send_cdp(ws, "Page.navigate", {"url": url})
    time.sleep(wait_seconds)


def check_logged_in(ws):
    result = eval_js(ws, "document.title")
    title = result.get("raw", "") if isinstance(result, dict) else str(result)
    if "Log in" in title or "Login" in title or "Sign in" in title:
        return False
    url_result = eval_js(ws, "window.location.href")
    url = url_result.get("raw", "") if isinstance(url_result, dict) else str(url_result)
    if "accounts/login" in url:
        return False
    return True


# ---------------------------------------------------------------------------
# Audit-specific API helpers. Each function does one fetch call inside the
# logged-in browser context.
# ---------------------------------------------------------------------------

def viewer_identity(ws):
    """Return {username, user_id} of the logged-in viewer, or {error: ...}."""
    js = r"""
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const resp = await fetch('/api/v1/accounts/current_user/?edit=true', {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (!resp.ok) return JSON.stringify({error: 'HTTP ' + resp.status});
        const j = await resp.json();
        const u = j?.user || {};
        return JSON.stringify({username: u.username, user_id: String(u.pk || u.id || '')});
    })()
    """
    return eval_js(ws, js)


def resolve_user_id(ws, handle):
    profile_url = f"https://www.instagram.com/{handle}/"
    sys.stderr.write(f"Navigating to {profile_url}...\n")
    send_cdp(ws, "Page.navigate", {"url": profile_url})
    time.sleep(4)

    url_result = eval_js(ws, "window.location.href")
    current_url = url_result.get("raw", "") if isinstance(url_result, dict) else str(url_result)
    if "accounts/login" in current_url:
        return {"error": "Redirected to login. Session may be expired or rate-limited."}

    js = r"""
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const infoResp = await fetch('/api/v1/users/web_profile_info/?username=' + encodeURIComponent(location.pathname.replace(/\//g, '')), {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (infoResp.ok) {
            const info = await infoResp.json();
            const uid = info?.data?.user?.id;
            if (uid) return JSON.stringify({user_id: uid});
        }
        return JSON.stringify({error: 'user_id not found'});
    })()
    """
    res = eval_js(ws, js)
    if isinstance(res, dict) and res.get("user_id"):
        return res["user_id"]
    return {"error": f"Could not determine user_id for @{handle}", "detail": res}


def fetch_tagged_feed(ws, user_id, since_ts, debug=False):
    """Paginate /api/v1/usertags/<user_id>/feed/ until items predate since_ts.

    Returns a list of dicts:
        {media_id, shortcode, taken_at, taken_at_iso, owner_username, owner_id,
         media_type, url, caption}
    """
    items = []
    max_id = None
    page = 0
    while True:
        page += 1
        params = "count=18"
        if max_id:
            params += f"&max_id={max_id}"
        js = f"""
        (async () => {{
            const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
            const resp = await fetch('/api/v1/usertags/{user_id}/feed/?{params}', {{
                credentials: 'include',
                headers: {{
                    'X-IG-App-ID': '936619743392459',
                    'X-CSRFToken': csrf,
                    'X-Requested-With': 'XMLHttpRequest',
                }}
            }});
            if (!resp.ok) return JSON.stringify({{error: 'HTTP ' + resp.status}});
            return JSON.stringify(await resp.json());
        }})()
        """
        data = eval_js(ws, js)
        if debug:
            with open(f"/tmp/instagram-audit-tagged-feed-p{page}.json", "w") as f:
                json.dump(data, f, indent=2)
        if isinstance(data, dict) and data.get("error"):
            sys.stderr.write(f"tagged-feed page {page}: {data['error']}\n")
            break
        raw_items = data.get("items", []) if isinstance(data, dict) else []
        if not raw_items:
            break
        oldest_on_page = None
        for it in raw_items:
            ts = it.get("taken_at", 0)
            oldest_on_page = ts if oldest_on_page is None else min(oldest_on_page, ts)
            owner = it.get("user", {}) or {}
            short = it.get("code") or it.get("shortcode") or ""
            items.append({
                "media_id": str(it.get("pk") or it.get("id") or ""),
                "shortcode": short,
                "taken_at": ts,
                "taken_at_iso": datetime.fromtimestamp(ts, timezone.utc).isoformat() if ts else None,
                "owner_username": owner.get("username"),
                "owner_id": str(owner.get("pk") or owner.get("id") or ""),
                "media_type": _media_type_label(it.get("media_type")),
                "url": f"https://www.instagram.com/p/{short}/" if short else None,
                "caption": (it.get("caption") or {}).get("text") if isinstance(it.get("caption"), dict) else None,
            })
        sys.stderr.write(f"tagged-feed page {page}: {len(raw_items)} items (cum {len(items)})\n")
        if oldest_on_page is not None and oldest_on_page < since_ts:
            break
        if not data.get("more_available"):
            break
        max_id = data.get("next_max_id")
        if not max_id:
            break
        time.sleep(2)
    return [x for x in items if x["taken_at"] and x["taken_at"] >= since_ts]


def fetch_activity_inbox(ws, since_ts, debug=False):
    """Pull /api/v1/news/inbox/ and filter for story-mention + post-tag entries.

    Returns a list of dicts:
        {kind, timestamp, timestamp_iso, actor_username, actor_id, media_id,
         story_type, text}
    where `kind` is 'story_mention' or 'post_tag' or 'unknown_tag'.
    Coverage is limited by Instagram's notification retention (~14-30 days).
    """
    js = r"""
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const resp = await fetch('/api/v1/news/inbox/?mark_as_seen=false', {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (!resp.ok) return JSON.stringify({error: 'HTTP ' + resp.status});
        return JSON.stringify(await resp.json());
    })()
    """
    data = eval_js(ws, js)
    if debug:
        with open("/tmp/instagram-audit-activity-inbox.json", "w") as f:
            json.dump(data, f, indent=2)
    if isinstance(data, dict) and data.get("error"):
        return {"error": data["error"]}

    notifs = []
    buckets = []
    if isinstance(data, dict):
        for key in ("new_stories", "old_stories", "stories", "counts"):
            v = data.get(key)
            if isinstance(v, list):
                buckets.extend(v)
        # Some payloads nest under "stories" wrappers
        for w in data.get("subscriptions", []) or []:
            if isinstance(w, dict) and isinstance(w.get("stories"), list):
                buckets.extend(w["stories"])

    for n in buckets:
        if not isinstance(n, dict):
            continue
        args = n.get("args", {}) or {}
        ts = args.get("timestamp") or n.get("timestamp")
        if not ts:
            continue
        ts_int = int(float(ts))
        if ts_int < since_ts:
            continue
        text = args.get("text") or n.get("text") or ""
        story_type = n.get("story_type")
        kind = _classify_notif(text, story_type)
        if kind == "skip":
            continue
        # actor: try args.profile_id + args.profile_name first
        actor_username = args.get("profile_name") or args.get("username") or None
        actor_id = str(args.get("profile_id") or "")
        if not actor_username and isinstance(args.get("links"), list) and args["links"]:
            link = args["links"][0]
            actor_username = link.get("title")
        media_id = ""
        for k in ("media_id", "media", "story_media_id"):
            v = args.get(k)
            if v:
                media_id = str(v)
                break
        if not media_id and isinstance(args.get("media"), list) and args["media"]:
            m0 = args["media"][0]
            media_id = str(m0.get("id") or m0.get("media_id") or "")
        notifs.append({
            "kind": kind,
            "timestamp": ts_int,
            "timestamp_iso": datetime.fromtimestamp(ts_int, timezone.utc).isoformat(),
            "actor_username": actor_username,
            "actor_id": actor_id,
            "media_id": media_id,
            "story_type": story_type,
            "text": text,
        })
    return sorted(notifs, key=lambda x: x["timestamp"], reverse=True)


def fetch_live_story_tray(ws, user_id, debug=False):
    """Fetch the target's currently-active stories (<24h).

    Returns a list of reel_media items with reshare metadata extracted.
    """
    js = f"""
    (async () => {{
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const resp = await fetch('/api/v1/feed/user/{user_id}/story/', {{
            credentials: 'include',
            headers: {{
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }}
        }});
        if (!resp.ok) return JSON.stringify({{error: 'HTTP ' + resp.status}});
        return JSON.stringify(await resp.json());
    }})()
    """
    data = eval_js(ws, js)
    if debug:
        with open("/tmp/instagram-audit-live-stories.json", "w") as f:
            json.dump(data, f, indent=2)
    if isinstance(data, dict) and data.get("error"):
        return {"error": data["error"]}
    reel = (data.get("reel") or {}) if isinstance(data, dict) else {}
    return [_extract_story_item(it) for it in (reel.get("items") or [])]


def fetch_own_story_archive(ws, viewer_user_id, target_user_id, since_ts, debug=False):
    """Pull own story archive day-shells back to since_ts.

    Only works if viewer_user_id == target_user_id (Instagram restricts archive
    access to the account owner). Returns a list of story items with reshare
    metadata, or {error: ...} if not accessible.
    """
    if str(viewer_user_id) != str(target_user_id):
        return {"error": "archive_not_accessible",
                "detail": "Story archive is only readable when logged in AS the target account."}

    js_calendar = r"""
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const resp = await fetch('/api/v1/archive/reel/day_shells/', {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (!resp.ok) return JSON.stringify({error: 'HTTP ' + resp.status});
        return JSON.stringify(await resp.json());
    })()
    """
    shells = eval_js(ws, js_calendar)
    if debug:
        with open("/tmp/instagram-audit-archive-shells.json", "w") as f:
            json.dump(shells, f, indent=2)
    if isinstance(shells, dict) and shells.get("error"):
        return {"error": f"archive shells: {shells['error']}"}

    items = []
    day_shells = (shells.get("day_shells") or shells.get("items") or []) if isinstance(shells, dict) else []
    for shell in day_shells:
        ts = shell.get("created_at") or shell.get("timestamp") or shell.get("date")
        if isinstance(ts, str):
            # Date string YYYY-MM-DD
            try:
                shell_ts = int(datetime.fromisoformat(ts).replace(tzinfo=timezone.utc).timestamp())
            except Exception:
                shell_ts = 0
        else:
            shell_ts = int(ts or 0)
        if shell_ts and shell_ts < since_ts - 86400:
            continue
        reel_id = shell.get("id") or shell.get("reel_id") or shell.get("pk")
        if not reel_id:
            continue
        js_reel = f"""
        (async () => {{
            const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
            const resp = await fetch('/api/v1/archive/reel/seen_media/?reel_ids={reel_id}', {{
                credentials: 'include',
                headers: {{
                    'X-IG-App-ID': '936619743392459',
                    'X-CSRFToken': csrf,
                    'X-Requested-With': 'XMLHttpRequest',
                }}
            }});
            if (!resp.ok) return JSON.stringify({{error: 'HTTP ' + resp.status}});
            return JSON.stringify(await resp.json());
        }})()
        """
        reel_data = eval_js(ws, js_reel)
        if isinstance(reel_data, dict) and not reel_data.get("error"):
            reels = reel_data.get("reels") or {}
            for _, reel in reels.items():
                for it in (reel.get("items") or []):
                    if it.get("taken_at", 0) >= since_ts:
                        items.append(_extract_story_item(it))
        time.sleep(1.5)
    if debug:
        with open("/tmp/instagram-audit-archive-items.json", "w") as f:
            json.dump(items, f, indent=2)
    return items


# ---------------------------------------------------------------------------
# Heuristics
# ---------------------------------------------------------------------------

def _media_type_label(t):
    return {1: "image", 2: "video", 8: "carousel"}.get(t, f"unknown_{t}")


def _classify_notif(text, story_type):
    text_lc = (text or "").lower()
    if "mentioned you in their story" in text_lc or "mentioned you in a story" in text_lc:
        return "story_mention"
    if "tagged you in" in text_lc and ("photo" in text_lc or "post" in text_lc or "reel" in text_lc):
        return "post_tag"
    # Numeric story_type fallbacks observed in the wild — 122/161 family for
    # story mentions, varies. Will not be relied on without text confirmation.
    return "skip"


def _extract_story_item(it):
    """Pull reshare-relevant fields off a reel_media item.

    Three signals (any one suggests a reshare):
      - reshared_reel_id: present when story is "Add to your story" of another reel
      - imported_taken_at: present when source media is older than this story (i.e. reshare)
      - reel_mentions targeting an actor: the @user overlay added to a reshare
    """
    rs_id = it.get("reshared_reel") or it.get("reshared_reel_id") or {}
    if isinstance(rs_id, dict):
        reshared_media_id = str(rs_id.get("id") or rs_id.get("media_id") or "")
        reshared_owner_id = str((rs_id.get("user") or {}).get("pk") or rs_id.get("user_id") or "")
    else:
        reshared_media_id = str(rs_id) if rs_id else ""
        reshared_owner_id = ""
    reel_mentions = []
    for m in (it.get("reel_mentions") or []):
        u = m.get("user") or {}
        if u.get("username"):
            reel_mentions.append({"username": u.get("username"),
                                  "user_id": str(u.get("pk") or u.get("id") or "")})
    ts = it.get("taken_at", 0)
    return {
        "media_id": str(it.get("pk") or it.get("id") or ""),
        "taken_at": ts,
        "taken_at_iso": datetime.fromtimestamp(ts, timezone.utc).isoformat() if ts else None,
        "media_type": _media_type_label(it.get("media_type")),
        "imported_taken_at": it.get("imported_taken_at"),
        "reshared_media_id": reshared_media_id,
        "reshared_owner_id": reshared_owner_id,
        "reel_mentions": reel_mentions,
    }


def match_reshare(tag, own_stories, window_seconds=86400):
    """Return the own-story dict that reshares `tag`, or None.

    A own-story matches when:
      A) Its `reshared_media_id` equals the tag's `media_id`, OR
      B) Any `reel_mentions[].user_id` equals the tag's `actor_id`/`owner_id`
         AND the story was posted within `window_seconds` after the tag.
    """
    tag_media = tag.get("media_id") or ""
    tag_actor = tag.get("actor_id") or tag.get("owner_id") or ""
    tag_ts = tag.get("timestamp") or tag.get("taken_at") or 0
    for s in own_stories:
        if tag_media and s.get("reshared_media_id") == tag_media:
            return s
        if tag_actor:
            for m in s.get("reel_mentions") or []:
                if m.get("user_id") == tag_actor:
                    dt = s.get("taken_at", 0) - tag_ts
                    if 0 <= dt <= window_seconds:
                        return s
    return None


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_audit(ws, handle, since_iso, debug):
    try:
        since_ts = int(datetime.fromisoformat(since_iso).replace(tzinfo=timezone.utc).timestamp())
    except ValueError:
        return {"error": f"Bad --since date: {since_iso}. Use YYYY-MM-DD."}

    viewer = viewer_identity(ws)
    if isinstance(viewer, dict) and viewer.get("error"):
        return {"error": f"viewer identity: {viewer['error']}"}

    user_id = resolve_user_id(ws, handle)
    if isinstance(user_id, dict):
        return user_id

    time.sleep(2)
    tagged_posts = fetch_tagged_feed(ws, user_id, since_ts, debug=debug)
    time.sleep(2)
    activity = fetch_activity_inbox(ws, since_ts, debug=debug)
    activity_err = activity.get("error") if isinstance(activity, dict) else None
    activity_list = activity if isinstance(activity, list) else []
    time.sleep(2)
    live_stories = fetch_live_story_tray(ws, user_id, debug=debug)
    live_err = live_stories.get("error") if isinstance(live_stories, dict) else None
    live_list = live_stories if isinstance(live_stories, list) else []
    time.sleep(2)
    archive = fetch_own_story_archive(ws, viewer.get("user_id"), user_id, since_ts, debug=debug)
    archive_err = archive.get("error") if isinstance(archive, dict) else None
    archive_list = archive if isinstance(archive, list) else []

    own_stories = live_list + archive_list

    missed_post_reshares = []
    matched_post_reshares = []
    for p in tagged_posts:
        tag = {"media_id": p["media_id"], "owner_id": p["owner_id"], "taken_at": p["taken_at"]}
        m = match_reshare(tag, own_stories)
        (matched_post_reshares if m else missed_post_reshares).append(p)

    missed_story_tags = []
    matched_story_tags = []
    for n in activity_list:
        if n["kind"] != "story_mention":
            continue
        tag = {"media_id": n["media_id"], "actor_id": n["actor_id"], "timestamp": n["timestamp"]}
        m = match_reshare(tag, own_stories)
        (matched_story_tags if m else missed_story_tags).append(n)

    now_ts = int(time.time())
    notes = []
    if archive_err == "archive_not_accessible":
        notes.append(
            f"Story archive unreadable: session is logged in as @{viewer.get('username')}, "
            f"not @{handle}. Reshare evidence older than 24h is not visible. To get a "
            f"complete audit, log in as @{handle} and re-run."
        )
    elif archive_err:
        notes.append(f"Story archive fetch failed: {archive_err}")
    if activity_err:
        notes.append(f"Activity inbox fetch failed: {activity_err}")
    notes.append(
        "Activity inbox typically retains story-mention notifications for roughly "
        "14-30 days. Tags older than that window are unrecoverable and not counted "
        "in 'story_tags_*' figures."
    )
    notes.append(
        "Customer-side stories expire 24h after posting. The audit can only confirm "
        "a tag existed if Instagram still shows the notification."
    )

    return {
        "target_handle": handle,
        "target_user_id": user_id,
        "viewer": viewer,
        "since": since_iso,
        "since_ts": since_ts,
        "as_of_iso": datetime.fromtimestamp(now_ts, timezone.utc).isoformat(),
        "coverage": {
            "tagged_posts": "full" if not isinstance(tagged_posts, dict) else "partial",
            "story_tag_notifications": "limited_to_instagram_retention" if not activity_err else "failed",
            "own_live_stories": "ok" if not live_err else f"failed: {live_err}",
            "own_story_archive": "ok" if archive_err is None else archive_err,
        },
        "summary": {
            "tagged_posts_total": len(tagged_posts),
            "tagged_posts_reshared": len(matched_post_reshares),
            "tagged_posts_missed": len(missed_post_reshares),
            "story_tags_in_activity_total": len([n for n in activity_list if n["kind"] == "story_mention"]),
            "story_tags_reshared": len(matched_story_tags),
            "story_tags_missed": len(missed_story_tags),
        },
        "missed_post_reshares": missed_post_reshares,
        "missed_story_tags": missed_story_tags,
        "matched_post_reshares": matched_post_reshares,
        "matched_story_tags": matched_story_tags,
        "notes": notes,
    }


def main():
    parser = argparse.ArgumentParser(description="Audit Instagram tag reshares for SOP D40 compliance.")
    sub = parser.add_subparsers(dest="command")
    p = sub.add_parser("audit", help="Run the tag-reshare audit.")
    p.add_argument("handle", help="Target handle (e.g. example_account, without @).")
    p.add_argument("--since", required=True, help="YYYY-MM-DD, UTC.")
    p.add_argument("--debug", action="store_true",
                   help="Dump raw API responses to /tmp/instagram-audit-*.json.")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    ws_url = os.environ.get("CDP_WS_URL")
    if not ws_url:
        sys.stderr.write("ERROR: CDP_WS_URL not set; run via: "
                         "not-google-chrome --cdp -- python3 audit-tag-reshares.py ...\n")
        sys.exit(1)

    ws = _ws_connect(ws_url, timeout=20)
    send_cdp(ws, "Page.enable")
    navigate_and_wait(ws, "https://www.instagram.com/", wait_seconds=3)
    if not check_logged_in(ws):
        print(json.dumps({
            "error": "Not logged in to Instagram. Log in via a Chrome-compatible browser first."
        }))
        sys.exit(1)
    time.sleep(2)

    if args.command == "audit":
        result = cmd_audit(ws, args.handle, args.since, args.debug)
    else:
        result = {"error": f"Unknown command: {args.command}"}

    print(json.dumps(result, indent=2, ensure_ascii=False))
    _ws_close(ws)


if __name__ == "__main__":
    main()

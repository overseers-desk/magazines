"""Signed-in reads of the Slush event platform (platform.slush.org) over plain HTTP.

The platform is a single-page app over three JSON services:

  auth.slush.org     GET /auth/csrf-token, then POST /auth/login/credentials
                     {email, password, rememberMe} with x-csrf-token and
                     x-auth-transport: cookie. A good login answers
                     {"success": true, "token": <access token>}.
  engine.slush.org   the account's data. Takes the token raw in Authorization;
                     with a "Bearer " prefix it answers 401.
  search.slush.org   the side-event catalogue. Answers signed out too, but with
                     fewer events (316 of 398 on 2026-11-12), so it gets the token.

Each Slush edition is a "target" (slush25, slush26, ...) named in the paths.

Credentials come from [slush.org] email / password in
$HOME/.config/magazines/config.ini, read here so they never pass on a command line.

The login endpoint answers 429 after a burst of sign-ins (six in about ten seconds
on 2026-11-12), so a run reuses the token the last login stored in
$XDG_CACHE_HOME/magazines/slush.org.json (mode 600, keyed by email) and signs in
again only when the platform refuses it.
"""

import configparser
import http.cookiejar
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

AUTH = "https://auth.slush.org"
ENGINE = "https://engine.slush.org"
SEARCH = "https://search.slush.org"
TARGET = "slush26"
VENUE_TZ = ZoneInfo("Europe/Helsinki")
# Tested against auth/engine/search.slush.org on 2026-11-12.
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
_REFUSED = object()  # _call's answer to a 401 when the caller asked to see it
_token = None
_email = None
user = {}


def emit_ok(result, has_more=False):
    print(json.dumps({"result": result, "identity": user.get("user_id"), "cursor": None,
                      "hasMore": has_more, "fault": None}, ensure_ascii=False, indent=1))


def fail(detail, code, shape="unrecognised"):
    """Fault envelope on stdout, the reason on stderr, then exit with code."""
    print(json.dumps({"result": None, "cursor": None, "hasMore": False,
                      "fault": {"shape": shape, "detail": str(detail)[:200]}}))
    print(detail, file=sys.stderr)
    sys.exit(code)


def no_session(reason):
    fail(f"session missing: slush.org, expected {_email}, {reason}", 77, "login_wall")


def local_time(iso):
    """An API timestamp (UTC, ISO 8601) in venue time, e.g. "2026-11-18 17:00"."""
    if not iso:
        return None
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(VENUE_TZ).strftime("%Y-%m-%d %H:%M")


def _call(url, payload=None, headers=None, refused_ok=False):
    hdrs = {"User-Agent": UA, "Origin": "https://platform.slush.org",
            "Referer": "https://platform.slush.org/", "Content-Type": "application/json",
            "x-auth-transport": "cookie"}
    if _token:
        hdrs["Authorization"] = _token
    hdrs.update(headers or {})
    data = json.dumps(payload).encode() if payload is not None else None
    try:
        with _opener.open(urllib.request.Request(url, data=data, headers=hdrs), timeout=30) as f:
            return json.loads(f.read() or b"null")
    except urllib.error.HTTPError as e:
        if e.code == 401:
            if refused_ok:
                return _REFUSED
            no_session(f"{url} answered 401")
        if e.code == 429:
            fail(f"{url} answered 429 (rate limited); wait a few minutes and retry", 75)
        fail(f"{url} answered HTTP {e.code}", 65)
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        fail(f"{url}: {e}", 65)


def _cache_path():
    base = pathlib.Path(os.environ.get("XDG_CACHE_HOME") or pathlib.Path.home() / ".cache")
    return base / "magazines" / "slush.org.json"


def _cached_token():
    try:
        saved = json.loads(_cache_path().read_text())
    except (OSError, ValueError):
        return None
    return saved.get("token") if saved.get("email") == _email else None


def _store_token():
    path = _cache_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"email": _email, "token": _token}, f)


def login():
    global _token, _email, user
    base = pathlib.Path(os.environ.get("XDG_CONFIG_HOME") or pathlib.Path.home() / ".config")
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(base / "magazines" / "config.ini")
    _email = cp.get("slush.org", "email", fallback="")
    password = cp.get("slush.org", "password", fallback="")
    missing = [k for k, v in (("email", _email), ("password", password)) if not v]
    if missing:
        fail("~/.config/magazines/config.ini has no [slush.org] " + ", ".join(missing), 78)

    _token = _cached_token()
    if _token:
        me = _call(ENGINE + "/users/me", refused_ok=True)
        if me is not _REFUSED:
            user = (me or {}).get("user") or {}
            if user.get("user_id"):
                return
        _token = None

    csrf = (_call(AUTH + "/auth/csrf-token") or {}).get("csrfToken")
    if not csrf:
        fail("auth.slush.org gave no CSRF token", 65)
    body = _call(AUTH + "/auth/login/credentials",
                 {"email": _email, "password": password, "rememberMe": False},
                 {"x-csrf-token": csrf}) or {}
    if not body.get("success") or not body.get("token"):
        no_session(body.get("message") or "login rejected")
    _token = body["token"]
    user = (get("/users/me") or {}).get("user") or {}
    if not user.get("user_id"):
        no_session("/users/me named nobody")
    _store_token()


def get(path):
    return _call(ENGINE + path)


def search(target, path, options, size):
    return _call(SEARCH + path, {"options": dict(options, page={"from": 0, "size": size}),
                                 "target_ids": [target]})


def add_target_arg(parser):
    parser.add_argument("--target", default=TARGET, help=f"Slush edition id (default {TARGET})")

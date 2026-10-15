#!/usr/bin/env python3
"""Refuse a SerpApi call made anywhere but commands/serpapi/search.py.

The script saves every response and answers an identical request from the
saved file, so a hand-built curl, an inline urllib call or a WebFetch of the
API buys a search the store may already hold. A shell command naming
serpapi.com together with the key (api_key or SERPAPI_KEY), or a WebFetch of
the API endpoints, is denied with the script's path; serpapi.com's
documentation pages, any other command, and malformed input pass silently.
--test runs the self-suite.
"""

import json
import os
import sys
from urllib.parse import urlparse

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "commands", "serpapi", "search.py")


KEY_MARKS = ("api_key", "SERPAPI_KEY")
API_PATHS = ("/search", "/search.json", "/account", "/account.json")


def reason():
    return (
        f"SerpApi calls go through `python3 {SCRIPT} <flights|search|maps|reviews|hotels|account> ...`. "
        "It saves every response and answers an identical request from the saved file instead of "
        "buying another search. A field its formatted output leaves out is in the raw JSON file it "
        "names on stderr (raw: <path>): read that file. Searches used and left: `account`, which "
        "costs no search."
    )


def check(tool_name, tool_input):
    """Return the refusal text for a SerpApi call that bypasses the script, else None."""
    if tool_name == "Bash":
        command = tool_input.get("command") or ""
        if "serpapi.com" in command and any(mark in command for mark in KEY_MARKS):
            return reason()
    elif tool_name == "WebFetch":
        url = urlparse(tool_input.get("url") or "")
        host = (url.hostname or "").lower()
        if host == "serpapi.com" or host.endswith(".serpapi.com"):
            if url.path in API_PATHS or url.path.startswith("/searches/"):
                return reason()
    return None


def run_tests():
    failures = []

    def ok(name, cond):
        print(("PASS" if cond else "FAIL"), name)
        if not cond:
            failures.append(name)

    def bash(cmd):
        return check("Bash", {"command": cmd})

    def fetch(url):
        return check("WebFetch", {"url": url, "prompt": "x"})

    ok("account curl refused",
       bash('curl -s "https://serpapi.com/account.json?api_key=${SERPAPI_KEY:-$(ini serpapi api_key)}"') is not None)
    ok("hotels curl refused",
       bash('curl -s "https://serpapi.com/search.json?engine=google_hotels&q=x&api_key=$SERPAPI_KEY"') is not None)
    ok("inline urllib refused",
       bash("python3 - <<'EOF'\nimport os, urllib.request\n"
            "urllib.request.urlopen('https://serpapi.com/search.json?q=x&api_key=' + os.environ['SERPAPI_KEY'])\nEOF")
       is not None)
    ok("WebFetch of search.json refused",
       fetch("https://serpapi.com/search.json?engine=google&q=x&api_key=k") is not None)
    ok("WebFetch of account.json refused", fetch("https://serpapi.com/account.json?api_key=k") is not None)
    ok("WebFetch of a search archive refused", fetch("https://serpapi.com/searches/abc/def.json") is not None)
    r = bash('curl "https://serpapi.com/search?q=x&api_key=k"')
    ok("refusal names the script", r is not None and SCRIPT in r)

    ok("script call passes", bash('python3 /x/commands/serpapi/search.py maps "x"') is None)
    ok("script call with key in env passes",
       bash('SERPAPI_KEY=k python3 /x/commands/serpapi/search.py search "y"') is None)
    ok("commit message naming serpapi.com passes", bash('git commit -m "serpapi: link serpapi.com docs"') is None)
    ok("grep for serpapi.com passes", bash("grep -rn serpapi.com commands/") is None)
    ok("docs page passes", fetch("https://serpapi.com/google-hotels-api") is None)
    ok("search-api docs page passes", fetch("https://serpapi.com/search-api") is None)
    ok("other host passes", fetch("https://example.com/search.json?api_key=k") is None)
    ok("other tool passes", check("Read", {"file_path": "/x/serpapi.com"}) is None)
    ok("missing input passes", check("Bash", {}) is None)

    print(f"{len(failures)} failures")
    return 1 if failures else 0


def main():
    if "--test" in sys.argv:
        sys.exit(run_tests())
    try:
        data = json.load(sys.stdin)
        reason = check(data.get("tool_name"), data.get("tool_input") or {})
    except Exception:
        sys.exit(0)
    if reason:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }))
    sys.exit(0)


if __name__ == "__main__":
    main()

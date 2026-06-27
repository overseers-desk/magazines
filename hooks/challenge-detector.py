#!/usr/bin/env python3
"""Stop hook: challenge a confident, unsourced assertion before the turn ends.

The user repeatedly catches the assistant stating a cause, state, identity,
or quantity as settled fact with no provenance, and has to spend his own
attention firing a "what makes you think / how do you know" challenge. This
hook fires that challenge in his place: when the final assistant message
carries the lexical shape of a confident provenance-free claim, it blocks the
stop and asks the assistant to substantiate, cite, or label the claim an
assumption. The assistant answers without the user lifting a finger; a
misfire costs only a sentence of substantiation, never the user's time.

Detection is regex, deliberately. An LLM judge discriminates better, but
`claude -p` costs ~40s wall in this environment and there is no fast API
path, so it cannot run inside a blocking hook. The seven patterns below were
measured against 28 real Opus-authored challenged assertions and 200 normal
Opus messages: 57% recall at 12% false-positive. They catch the loud,
lexically-marked overreaches; the bare declaratives with no marker
("two-day event", an identity mapping) are the LLM judge's job, deferred.
The measurement, corpus, and rejected candidates (notably an unsourced-number
regex dropped for 19% FP) are in
labs/2026-07-opus-4-8-challenge-detector/.
"""

# TODO: LLM judge. Replace or back this regex with a judge that reads the
# message and answers "is any claim asserted as fact without verification?".
# It must run out-of-band (async, result delivered next turn) because of the
# ~40s claude -p latency noted above; a synchronous judge would freeze every
# turn. See the lab worklog for the latency finding and the misses it targets.

import json
import re
import sys

# Shipped regex set (kept in lockstep with labs/.../score.sh).
PATTERNS = {
    "definite_cause": r"the (reason|cause|culprit|problem|answer|diagnosis|explanation|fix|tell) (is|was)|is the (reason|cause|culprit|problem|answer|diagnosis)",
    "confident_absence": r"no (such|public|server|native|other|usable|team|hsm|cash|inbox|trace|rebase|web)|there (is|are) no |does.?t exist|not (on|in|present|externally|built|documented|needed)|nothing (breaks|exists)",
    "dichotomy_not": r", not (a|an|the|just|merely|add)|is a real",
    "modal_must": r"must be|has to be|have to be|had to be|can only be|cannot|can.?t |would (conflict|break|fail|be a no-op)",
    "causal_so": r"[,;] so (it|that|this|the|i)\b",
    "certainty_adverb": r"clearly|obviously|evidently|undoubtedly|certainly|definitely|unambiguously|of course|in fact|actually",
    "proof_verb": r"proves|confirms|confirming|demonstrates|shows that",
}
COMPILED = {k: re.compile(v, re.I) for k, v in PATTERNS.items()}


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    # Already re-entered after a prior block: the assistant is mid-substantiation.
    # Do not challenge again, or the turn never settles.
    if data.get("stop_hook_active"):
        sys.exit(0)

    msg = data.get("last_assistant_message") or ""
    if not isinstance(msg, str) or not msg.strip():
        sys.exit(0)

    hit = None
    for name, rx in COMPILED.items():
        m = rx.search(msg)
        if m:
            start = max(0, m.start() - 30)
            end = min(len(msg), m.end() + 30)
            hit = re.sub(r"\s+", " ", msg[start:end]).strip()
            break
    if not hit:
        sys.exit(0)

    reason = (
        "Before finishing — you stated something as settled fact: “…"
        + hit
        + "…”. What makes you think so? Show how you verified it, cite "
        "where it came from, or label it an assumption. If you already "
        "substantiated it above, point to where. If it was only a figure of "
        "speech and nothing rests on it, say so and finish."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


if __name__ == "__main__":
    main()

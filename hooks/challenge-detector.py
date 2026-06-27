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
path, so it cannot run inside a blocking hook. The three patterns below come
from a larger candidate set scored against 28 real Opus-authored challenged
assertions and 200 normal Opus messages, then narrowed after a live-traffic
check: the wider set fired on 37% of real messages (mostly ordinary careful
writing), so four noisy patterns were dropped. The shipped three score 25%
recall / 2% false-positive on the benchmark and fire on ~11% of live
messages. They catch claimed-absences and stated causes; everything subtler —
the bare declaratives, and the recall the drop gave up — is the LLM judge's
job, deferred.
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
# Tightened to the three high-signal patterns after a live-traffic check (see
# the worklog's dated update): the four dropped patterns (dichotomy_not,
# causal_so, modal_must, certainty_adverb) matched ordinary careful writing —
# a correct "X, not Y" distinction, a causal "so", a "cannot" — and drove the
# fire rate to 37% of real messages with little of it genuine. These three
# catch claimed-absences and stated causes, where the real overreach lives.
PATTERNS = {
    "definite_cause": r"the (reason|cause|culprit|problem|answer|diagnosis|explanation|fix|tell) (is|was)|is the (reason|cause|culprit|problem|answer|diagnosis)",
    "confident_absence": r"no (such|public|server|native|other|usable|team|hsm|cash|inbox|trace|rebase|web)|there (is|are) no |does.?t exist|not (on|in|present|externally|built|documented|needed)|nothing (breaks|exists)",
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

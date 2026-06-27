#!/usr/bin/env bash
# Reproduce the challenge-detector regex scoring against the labelled corpus.
# Run from this directory (reads positives.txt / negatives.txt beside it).
# Re-run a year later, or with a new model's data, by replacing the two corpora
# and running this unchanged: the regex set and the arithmetic are fixed here.
cd "$(dirname "$0")"
P=positives.txt; N=negatives.txt
np=$(grep -c . "$P"); nn=$(grep -c . "$N")

# All candidate patterns. SHIPPED ones are live in the hook; the rest are kept
# here as documented rejects (see the worklog) so their dynamics stay visible.
declare -A R
R[definite_cause]='the (reason|cause|culprit|problem|answer|diagnosis|explanation|fix|tell) (is|was)|is the (reason|cause|culprit|problem|answer|diagnosis)'
R[confident_absence]='no (such|public|server|native|other|usable|team|hsm|cash|inbox|trace|rebase|web)|there (is|are) no |does.?t exist|not (on|in|present|externally|built|documented|needed)|nothing (breaks|exists)'
R[proof_verb]='proves|confirms|confirming|demonstrates|shows that'
R[dichotomy_not]=', not (a|an|the|just|merely|add)|is a real'
R[modal_must]='must be|has to be|have to be|had to be|can only be|cannot|can.?t |would (conflict|break|fail|be a no-op)'
R[causal_so]='[,;] so (it|that|this|the|i)\b'
R[certainty_adverb]='clearly|obviously|evidently|undoubtedly|certainly|definitely|unambiguously|of course|in fact|actually'
R[unsourced_number]='~ ?[0-9$£]|approximately [0-9]|roughly [0-9]|[0-9][0-9,]*[–-][0-9][0-9,]*|[0-9]+%|[0-9]{3,}'

SHIPPED="definite_cause confident_absence proof_verb"
DROPPED="dichotomy_not causal_so modal_must certainty_adverb unsourced_number"

pct(){ awk "BEGIN{printf \"%.0f\", $1*100/$2}"; }
printf '%-18s %8s %7s  %s\n' "regex" "recall" "FP%" "status"
for k in $SHIPPED; do
  printf '%-18s %3d/%-3d %5s%%  shipped\n' "$k" "$(grep -icE "${R[$k]}" "$P")" "$np" "$(pct "$(grep -icE "${R[$k]}" "$N")" "$nn")"
done
for k in $DROPPED; do
  printf '%-18s %3d/%-3d %5s%%  dropped\n' "$k" "$(grep -icE "${R[$k]}" "$P")" "$np" "$(pct "$(grep -icE "${R[$k]}" "$N")" "$nn")"
done

ALL_SHIPPED=$(for k in $SHIPPED; do printf '%s|' "${R[$k]}"; done | sed 's/|$//')
echo "---"
echo "SHIPPED (3 regexes):  recall $(grep -icE "$ALL_SHIPPED" "$P")/$np ($(pct "$(grep -icE "$ALL_SHIPPED" "$P")" "$np")%)   FP $(grep -icE "$ALL_SHIPPED" "$N")/$nn ($(pct "$(grep -icE "$ALL_SHIPPED" "$N")" "$nn")%)"

if [ "$1" = "--per-line" ]; then
  echo "--- per positive: matched_by (shipped only) ---"
  while IFS= read -r line; do
    hits=""
    for k in $SHIPPED; do echo "$line" | grep -qiE "${R[$k]}" && hits="${hits:+$hits,}$k"; done
    printf '%s\t%s\n' "${hits:-NONE}" "$line"
  done < "$P"
fi

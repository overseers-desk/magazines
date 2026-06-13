#!/usr/bin/env bash
#
# typst-pdf — render a markdown file to PDF via Typst, with optional per-repo
# template discovered at .aesop/default.typ or .aesop/letterhead.typ.
#
# This driver is intentionally agnostic about fonts, brands, repos, and other
# caller-specific concerns. All such concerns live in the discovered template.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: typst-pdf.sh <input.md> [options]

Options:
  --letterhead         Apply .aesop/letterhead.typ from the repo root
  --no-letterhead      Apply .aesop/default.typ even if letterhead.typ exists
  --out <path>         Output PDF path (skips the save-location prompt)
  --view               Open the PDF after compilation
  -h, --help           Show this help
EOF
}

INPUT=""
LETTERHEAD_PREF=""   # "" | yes | no
OUT=""
VIEW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --letterhead)    LETTERHEAD_PREF="yes"; shift ;;
    --no-letterhead) LETTERHEAD_PREF="no";  shift ;;
    --out)           OUT="$2"; shift 2 ;;
    --view)          VIEW=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; break ;;
    -*)              echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$INPUT" ]]; then
        INPUT="$1"
      else
        echo "Multiple input files not supported in v1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "Error: no input file specified" >&2
  usage >&2
  exit 2
fi
if [[ ! -f "$INPUT" ]]; then
  echo "Error: input file not found: $INPUT" >&2
  exit 1
fi

for cmd in typst pandoc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd not found on PATH." >&2
    case "$cmd" in
      typst)
        case "$(uname -s)" in
          Darwin) echo "Install: brew install typst" >&2 ;;
          Linux)  echo "Install: sudo snap install typst" >&2 ;;
          *)      echo "Install: see https://typst.app" >&2 ;;
        esac
        ;;
      pandoc)
        case "$(uname -s)" in
          Darwin) echo "Install: brew install pandoc" >&2 ;;
          Linux)  echo "Install: sudo apt install pandoc (Debian/Ubuntu) or your distro's equivalent" >&2 ;;
          *)      echo "Install: see https://pandoc.org" >&2 ;;
        esac
        ;;
    esac
    exit 1
  fi
done

INPUT_ABS="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
INPUT_DIR="$(dirname "$INPUT_ABS")"
INPUT_STEM="$(basename "$INPUT_ABS" .md)"

REPO_ROOT=""
if git -C "$INPUT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT="$(git -C "$INPUT_DIR" rev-parse --show-toplevel)"
fi

TEMPLATE_BASENAME=""
if [[ -n "$REPO_ROOT" ]]; then
  HAS_DEFAULT=0; HAS_LETTER=0
  [[ -f "$REPO_ROOT/.aesop/default.typ"    ]] && HAS_DEFAULT=1
  [[ -f "$REPO_ROOT/.aesop/letterhead.typ" ]] && HAS_LETTER=1

  case "$LETTERHEAD_PREF" in
    yes)
      if [[ $HAS_LETTER -eq 1 ]]; then
        TEMPLATE_BASENAME="letterhead.typ"
      else
        echo "Error: --letterhead requested but $REPO_ROOT/.aesop/letterhead.typ not found" >&2
        exit 1
      fi
      ;;
    no)
      [[ $HAS_DEFAULT -eq 1 ]] && TEMPLATE_BASENAME="default.typ"
      ;;
    "")
      if [[ $HAS_LETTER -eq 1 && $HAS_DEFAULT -eq 1 ]]; then
        echo "Error: repo has both .aesop/default.typ and .aesop/letterhead.typ; pass --letterhead or --no-letterhead" >&2
        exit 2
      elif [[ $HAS_LETTER -eq 1 ]]; then
        TEMPLATE_BASENAME="letterhead.typ"
      elif [[ $HAS_DEFAULT -eq 1 ]]; then
        TEMPLATE_BASENAME="default.typ"
      fi
      ;;
  esac
fi

if [[ -z "$OUT" ]]; then
  SUGGEST=""
  case "$(uname -s)" in
    Darwin)
      SUGGEST="$HOME/Documents"
      ;;
    Linux)
      if command -v xdg-user-dir >/dev/null 2>&1; then
        SUGGEST="$(xdg-user-dir DOCUMENTS 2>/dev/null || true)"
      fi
      if [[ -z "$SUGGEST" && -f "$HOME/.config/user-dirs.dirs" ]]; then
        SUGGEST="$(awk -F= '/^XDG_DOCUMENTS_DIR/ {gsub(/"/, "", $2); print $2}' \
          "$HOME/.config/user-dirs.dirs" | sed "s|\\\$HOME|$HOME|")"
      fi
      [[ -z "$SUGGEST" ]] && SUGGEST="$HOME/Documents"
      ;;
    *)
      SUGGEST="$HOME"
      ;;
  esac
  [[ -d "$SUGGEST" ]] || SUGGEST="$HOME"

  echo "Error: --out <file.pdf> is required. Suggested: $SUGGEST/$INPUT_STEM.pdf" >&2
  exit 2
fi

OUT="${OUT/#\~/$HOME}"
if [[ -d "$OUT" ]]; then
  echo "Error: --out points to an existing directory: $OUT" >&2
  exit 2
fi
OUT_DIR="$(dirname "$OUT")"
[[ -d "$OUT_DIR" ]] || mkdir -p "$OUT_DIR"

TMP="$(mktemp -d)"
WRAPPER_IN_REPO=""
cleanup() {
  rm -rf "$TMP"
  if [[ -n "$WRAPPER_IN_REPO" && -f "$WRAPPER_IN_REPO" ]]; then
    rm -f "$WRAPPER_IN_REPO"
  fi
  return 0
}
trap cleanup EXIT

BODY="$TMP/body.typ"
pandoc -t typst -o "$BODY" "$INPUT_ABS"

if [[ -n "$TEMPLATE_BASENAME" ]]; then
  WRAPPER_IN_REPO="$REPO_ROOT/.aesop/.aesop-build.$$.typ"
  {
    printf '#import "%s": template\n' "$TEMPLATE_BASENAME"
    printf '#show: template\n\n'
    cat "$BODY"
  } > "$WRAPPER_IN_REPO"
  typst compile --root "$REPO_ROOT" "$WRAPPER_IN_REPO" "$OUT"
else
  typst compile --root "$(dirname "$BODY")" "$BODY" "$OUT"
fi

echo "Saved: $OUT" >&2

if [[ $VIEW -eq 1 ]]; then
  case "$(uname -s)" in
    Darwin) open "$OUT" ;;
    Linux)  xdg-open "$OUT" >/dev/null 2>&1 & ;;
  esac
fi

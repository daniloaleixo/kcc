#!/usr/bin/env bash
#
# batch_convert.sh — run kcc-c2e over every comic file in a folder, one ebook per file.
#
#   ./batch_convert.sh [options] <input-folder>
#
# Defaults target a Kindle 10th gen (K810) in AZW3, manga reading direction.
# AZW3 because Amazon discontinued kindlegen, so MOBI cannot be produced on Linux;
# KCC emits EPUB and Calibre's ebook-convert repacks it for USB sideloading.
# Already-converted chapters are skipped, so the script is safe to re-run after
# an interrupt or a partial failure.
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE="K810"
FORMAT="AZW3"
MANGA=1
OUTDIR=""
JOBS=1
DRY_RUN=0
KEEP_EPUB=0
EXTRA_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <input-folder>

Converts every comic file in <input-folder> to a separate ebook.

Options:
  -p, --profile PROFILE   Device profile          [default: $PROFILE]
  -f, --format FORMAT     Auto|MOBI|AZW3|EPUB|CBZ|PDF  [default: $FORMAT]
                          AZW3 is not a KCC format: KCC emits EPUB and Calibre's
                          ebook-convert repacks it. Sideloads to a Kindle over USB
                          without needing kindlegen.
      --keep-epub         With -f AZW3, keep the intermediate EPUB
  -o, --output DIR        Output directory        [default: <input-folder>/converted]
  -j, --jobs N            Convert N chapters at once. KCC already uses all cores
                          per chapter, so leave at 1 unless you have cores to spare.
                                                  [default: $JOBS]
      --no-manga          Left-to-right reading (drops -m)
      --dry-run           Print the commands without running them
  -h, --help              Show this help

Anything after -- is passed straight through to kcc-c2e.py, e.g.:
  $(basename "$0") ~/comics/Series -- --hq --cropping 2
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile) PROFILE="$2"; shift 2 ;;
        -f|--format)  FORMAT="$2";  shift 2 ;;
        -o|--output)  OUTDIR="$2";  shift 2 ;;
        -j|--jobs)    JOBS="$2";    shift 2 ;;
        --no-manga)   MANGA=0;      shift ;;
        --keep-epub)  KEEP_EPUB=1;  shift ;;
        --dry-run)    DRY_RUN=1;    shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; EXTRA_ARGS=("$@"); break ;;
        -*)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)            INPUT_DIR="${INPUT_DIR:-$1}"; shift ;;
    esac
done

if [[ -z "${INPUT_DIR:-}" ]]; then
    echo "Error: no input folder given." >&2
    usage >&2
    exit 2
fi
if [[ ! -d "$INPUT_DIR" ]]; then
    echo "Error: '$INPUT_DIR' is not a directory." >&2
    exit 2
fi

INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"
OUTDIR="${OUTDIR:-$INPUT_DIR/converted}"

# --- environment ------------------------------------------------------------
# kcc-c2e.py imports modify_path from the repo-root kcc.py, so it must run from
# the repo root. Prefer the repo venv over whatever python is active (conda base
# does not have KCC's dependencies).
if [[ -x "$REPO_DIR/venv/bin/python" ]]; then
    PYTHON="$REPO_DIR/venv/bin/python"
else
    PYTHON="$(command -v python3)"
    echo "Warning: $REPO_DIR/venv not found, falling back to $PYTHON" >&2
fi

if ! "$PYTHON" -c "import PIL, numpy, fitz, natsort, slugify, psutil" 2>/dev/null; then
    echo "Error: KCC's dependencies are missing from $PYTHON." >&2
    echo "  python3 -m venv '$REPO_DIR/venv'" >&2
    echo "  '$REPO_DIR/venv/bin/pip' install -r '$REPO_DIR/requirements.txt'" >&2
    exit 1
fi

# AZW3 is handled here, not by KCC: KCC emits EPUB and Calibre repacks it.
KCC_FORMAT="$FORMAT"
if [[ "$FORMAT" == "AZW3" ]]; then
    KCC_FORMAT="EPUB"
    if ! command -v ebook-convert >/dev/null 2>&1; then
        echo "Error: -f AZW3 needs Calibre's 'ebook-convert' on PATH." >&2
        echo "  sudo apt install calibre" >&2
        exit 1
    fi
fi

# MOBI output shells out to kindlegen, which is not a pip dependency.
if [[ "$KCC_FORMAT" == "MOBI" || "$KCC_FORMAT" == "MOBI+EPUB" || "$KCC_FORMAT" == "Auto" ]]; then
    if ! command -v kindlegen >/dev/null 2>&1; then
        echo "Error: format '$FORMAT' needs 'kindlegen' on PATH, and it is not installed." >&2
        echo "Amazon discontinued it and Kindle Previewer 3 is Windows/macOS only." >&2
        echo "Use -f AZW3 (Calibre, sideloads over USB) or -f EPUB (Send to Kindle)." >&2
        exit 1
    fi
fi

# --- collect input ----------------------------------------------------------
shopt -s nullglob nocaseglob
FILES=()
for f in "$INPUT_DIR"/*.pdf "$INPUT_DIR"/*.cbz "$INPUT_DIR"/*.cbr "$INPUT_DIR"/*.cb7 \
         "$INPUT_DIR"/*.zip "$INPUT_DIR"/*.rar "$INPUT_DIR"/*.7z "$INPUT_DIR"/*.epub; do
    [[ -f "$f" ]] && FILES+=("$f")
done
shopt -u nullglob nocaseglob

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No convertible files found in $INPUT_DIR" >&2
    exit 1
fi

# Natural sort so [0048] comes before [0100].
IFS=$'\n' FILES=($(printf '%s\n' "${FILES[@]}" | sort -V)); unset IFS

mkdir -p "$OUTDIR"
LOG="$OUTDIR/batch_convert.log"

echo "Input   : $INPUT_DIR (${#FILES[@]} files)"
echo "Output  : $OUTDIR"
echo "Profile : $PROFILE    Format: $FORMAT    Manga: $([[ $MANGA -eq 1 ]] && echo yes || echo no)"
echo "Log     : $LOG"
echo

# --- convert ----------------------------------------------------------------
convert_one() {
    local src="$1" idx="$2" total="$3"
    local stem; stem="$(basename "$src")"; stem="${stem%.*}"

    # Skip if any output for this chapter already exists (resumable re-runs).
    # Compared literally rather than by glob: these filenames start with things
    # like [0048], and in a glob that is a character class, not literal text.
    local out base
    for out in "$OUTDIR"/*; do
        [[ -f "$out" ]] || continue
        base="${out##*/}"
        case "${base,,}" in
            *.mobi|*.azw3|*.epub|*.cbz|*.pdf) ;;
            *) continue ;;
        esac
        if [[ "$base" == "$stem"* ]]; then
            printf '[%*d/%d] skip   %s (already converted)\n' "${#total}" "$idx" "$total" "$stem"
            return 0
        fi
    done

    local cmd=("$PYTHON" "$REPO_DIR/kcc-c2e.py"
               -p "$PROFILE" -f "$KCC_FORMAT" -o "$OUTDIR" -t "$stem")
    [[ $MANGA -eq 1 ]] && cmd+=(-m)
    [[ ${#EXTRA_ARGS[@]} -gt 0 ]] && cmd+=("${EXTRA_ARGS[@]}")
    cmd+=("$src")

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[%*d/%d] dry    %s\n' "${#total}" "$idx" "$total" "${cmd[*]}"
        [[ "$FORMAT" == "AZW3" ]] && printf '%*s          then: ebook-convert <epub> <azw3>\n' "${#total}" ""
        return 0
    fi

    printf '[%*d/%d] start  %s\n' "${#total}" "$idx" "$total" "$stem"
    if ! (cd "$REPO_DIR" && "${cmd[@]}") >>"$LOG" 2>&1; then
        printf '[%*d/%d] FAILED %s (see %s)\n' "${#total}" "$idx" "$total" "$stem" "$LOG"
        return 1
    fi

    if [[ "$FORMAT" == "AZW3" ]]; then
        # Repack every EPUB KCC produced for this chapter. Matched by literal
        # prefix, not glob, because these stems contain [nnnn].
        local epub found=0
        for epub in "$OUTDIR"/*; do
            [[ -f "$epub" ]] || continue
            base="${epub##*/}"
            [[ "${base,,}" == *.epub ]] || continue
            [[ "$base" == "$stem"* ]] || continue
            found=1
            if ebook-convert "$epub" "${epub%.epub}.azw3" >>"$LOG" 2>&1; then
                [[ $KEEP_EPUB -eq 0 ]] && rm -f "$epub"
            else
                printf '[%*d/%d] FAILED %s (ebook-convert, see %s)\n' \
                    "${#total}" "$idx" "$total" "$stem" "$LOG"
                return 1
            fi
        done
        if [[ $found -eq 0 ]]; then
            printf '[%*d/%d] FAILED %s (KCC produced no EPUB)\n' "${#total}" "$idx" "$total" "$stem"
            return 1
        fi
    fi

    printf '[%*d/%d] done   %s\n' "${#total}" "$idx" "$total" "$stem"
    return 0
}

TOTAL=${#FILES[@]}
FAILED=()
i=0

if [[ "$JOBS" -gt 1 ]]; then
    # Bounded parallelism: keep at most $JOBS conversions in flight.
    for src in "${FILES[@]}"; do
        i=$((i + 1))
        while [[ "$(jobs -rp | wc -l)" -ge "$JOBS" ]]; do wait -n; done
        convert_one "$src" "$i" "$TOTAL" &
    done
    wait
    echo
    echo "Finished ${TOTAL} file(s). Check $LOG for any FAILED entries."
else
    for src in "${FILES[@]}"; do
        i=$((i + 1))
        convert_one "$src" "$i" "$TOTAL" || FAILED+=("$(basename "$src")")
    done
    echo
    if [[ ${#FAILED[@]} -eq 0 ]]; then
        echo "All ${TOTAL} file(s) converted into $OUTDIR"
    else
        echo "${#FAILED[@]} of ${TOTAL} failed:"
        printf '  %s\n' "${FAILED[@]}"
        echo "Details in $LOG"
        exit 1
    fi
fi

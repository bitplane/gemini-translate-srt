#!/bin/bash
# Chunk a Whisper SRT file and translate into multiple languages via Gemini.
#
# Usage: ./translate-subs.sh <input.srt> <output_dir> <lang_code> [<lang_code>...]
# Example: ./translate-subs.sh subs.srt subs en es ja
#
# Approach: for each chunk we send Gemini only the *content* (no timestamps),
# line-numbered with <<N>> markers. The response is parsed by marker and merged
# back with the original SRT entries, so Gemini cannot cause timestamp drift —
# dropped lines become blank subtitles at the right time instead of shifting
# everything after them.
#
# Layout (relative to <output_dir>):
#   zh/chunks/chunk_NNN.srt           source SRT chunks
#   <lang>/chunks/chunk_NNN.zh.txt    numbered content sent to Gemini
#   <lang>/chunks/chunk_NNN.tr.txt    numbered translation from Gemini
#   <lang>/chunks/chunk_NNN.srt       reassembled SRT chunk
#   <lang>.srt                        concatenated, one per language

set -eu

INPUT="${1:?usage: $0 <input.srt> <output_dir> <lang_code> [lang_code...]}"
OUTDIR="${2:?usage: $0 <input.srt> <output_dir> <lang_code> [lang_code...]}"
shift 2
LANGS=("$@")

if [ ${#LANGS[@]} -eq 0 ]; then
    echo "need at least one target language code" >&2
    exit 1
fi

CHUNK_ENTRIES=100
MODEL="${CLAUDE_MODEL:-sonnet}"
CONTEXT="a Mandarin broadcast of the Beijing E-Town Half Marathon, featuring humanoid robots running alongside humans"
SCRIPT_DIR=$(dirname "$(realpath "$0")")
SRT_TOOL="$SCRIPT_DIR/srt-tool.py"

SYSTEM_PROMPT="You are translating Mandarin Chinese subtitles from a Whisper transcript of $CONTEXT.

Each input line has the format \"<<N>> content\", where N is a sequential number.

FORMATTING RULES (strict):
- Preserve the <<N>> prefix on every line exactly as it appears in the input.
- Output exactly one line per input line — never merge or split lines.
- Keep the same line order.
- Output only the numbered translated lines — no preamble, no code fences, no commentary.

HALLUCINATION HANDLING:
Whisper hallucinates YouTube credit/outro lines when audio is silent, music or crowd noise. If a line's content is clearly one of these, output just the prefix with blank content (e.g. \"<<7>> \"). Known patterns:
- Amara.org subtitle credits (由 Amara.org 社群提供的字幕 and variants)
- Subtitle attributions: 中文字幕: [name], 字幕組: [name] (often celebrities like 李宗盛)
- Outro boilerplate: 请订阅, 感谢观看, 谢谢大家, Thanks for watching
- The same line repeating verbatim across many consecutive 30-second segments
- Anything that clearly sounds like a YouTube credit rather than live sports commentary

PREFER TRANSLATING OVER BLANKING. Short utterances (好, 对, 嗯, 等一下, 跳起来), interjections, casual chatter, segment-break transitions, and closing remarks ARE legitimate content — translate them. Blanks are only for clear YouTube-artifact hallucinations."

mkdir -p "$OUTDIR"
INPUT_ABS=$(realpath "$INPUT")
OUTDIR=$(realpath "$OUTDIR")

lang_name() {
    case "$1" in
        en)       echo "English" ;;
        es)       echo "Spanish" ;;
        fr)       echo "French" ;;
        de)       echo "German" ;;
        it)       echo "Italian" ;;
        pt)       echo "Portuguese" ;;
        ru)       echo "Russian" ;;
        ja|jp)    echo "Japanese" ;;
        ko|kr)    echo "Korean" ;;
        ar)       echo "Arabic" ;;
        hi)       echo "Hindi" ;;
        zh|zh-cn) echo "Simplified Chinese" ;;
        zh-tw)    echo "Traditional Chinese" ;;
        *)        echo "$1" ;;
    esac
}

# 1. Chunk source
if ! compgen -G "$OUTDIR/zh/chunks/chunk_*.srt" >/dev/null; then
    echo "Chunking source into $CHUNK_ENTRIES-entry chunks..."
    python3 "$SRT_TOOL" chunk "$INPUT_ABS" "$OUTDIR/zh/chunks" "$CHUNK_ENTRIES"
fi
cp "$INPUT_ABS" "$OUTDIR/zh.srt"
N_CHUNKS=$(ls "$OUTDIR/zh/chunks/" | wc -l)
echo "Source chunks: $N_CHUNKS"

# 2. Translate each language
for LANG in "${LANGS[@]}"; do
    LNAME=$(lang_name "$LANG")
    mkdir -p "$OUTDIR/$LANG/chunks"
    echo "=== $LANG ($LNAME) ==="
    i=0
    for SRC in "$OUTDIR/zh/chunks/"chunk_*.srt; do
        i=$((i+1))
        NAME=$(basename "$SRC" .srt)
        DST="$OUTDIR/$LANG/chunks/$NAME.srt"
        ZH_NUM="$OUTDIR/$LANG/chunks/$NAME.zh.txt"
        TR_NUM="$OUTDIR/$LANG/chunks/$NAME.tr.txt"
        if [ -s "$DST" ]; then
            echo "  [$i/$N_CHUNKS] $NAME cached, skip"
            continue
        fi
        echo "  [$i/$N_CHUNKS] $NAME → $LNAME..."
        python3 "$SRT_TOOL" extract "$SRC" "$ZH_NUM"
        rm -f "$TR_NUM"
        USER_PROMPT="Translate the following lines to $LNAME:

$(cat "$ZH_NUM")"
        claude -p --tools "" --model "$MODEL" --output-format text \
            --system-prompt "$SYSTEM_PROMPT" \
            "$USER_PROMPT" > "$TR_NUM" 2> "$DST.log" || true
        if [ ! -s "$TR_NUM" ]; then
            if grep -qE 'rate.?limit|429|quota|usage.limit' "$DST.log" 2>/dev/null; then
                echo "    RATE LIMIT / QUOTA on $MODEL — aborting (see $DST.log)" >&2
                exit 2
            fi
            echo "    FAILED: no translation file produced (see $DST.log)" >&2
            exit 3
        fi
        python3 "$SRT_TOOL" reassemble "$SRC" "$TR_NUM" "$DST"
    done
    # Only combine if every chunk succeeded
    DONE_COUNT=$(ls "$OUTDIR/$LANG/chunks/"chunk_[0-9][0-9][0-9].srt 2>/dev/null | wc -l)
    if [ "$DONE_COUNT" -eq "$N_CHUNKS" ]; then
        cat "$OUTDIR/$LANG/chunks/"chunk_[0-9][0-9][0-9].srt > "$OUTDIR/$LANG.srt"
        echo "  combined → $OUTDIR/$LANG.srt"
    else
        echo "  SKIP combine: $DONE_COUNT/$N_CHUNKS chunks complete" >&2
    fi
done

echo "Done. Per-language SRT files:"
ls -la "$OUTDIR"/*.srt

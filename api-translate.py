#!/usr/bin/env python3
"""Translate a numbered-line chunk to another language via Claude Sonnet 4.6.

Input format: one line per subtitle, prefixed with `<<N>> ` where N is a
sequential integer. Output has the same shape with content translated.

Usage: api-translate.py <input.txt> <output.txt> <language-name> [--model MODEL]
"""

import argparse
import sys
from pathlib import Path

import anthropic


SYSTEM_PROMPT = """You are translating Mandarin Chinese subtitles from a Whisper transcript of a Mandarin broadcast of the Beijing E-Town Half Marathon, featuring humanoid robots running alongside humans.

Each input line has the format `<<N>> content`, where N is a sequential number.

FORMATTING RULES (strict):
- Preserve the `<<N>>` prefix on every line exactly as it appears in the input.
- Output exactly one line per input line — never merge or split lines.
- Keep the same line order.
- Output only the numbered translated lines — no preamble, no code fences, no commentary.

HALLUCINATION HANDLING:
Whisper hallucinates YouTube credit/outro lines when audio is silent, music or crowd noise. If a line's content is clearly one of these, output just the prefix with blank content (e.g. `<<7>> `). Known patterns:
- Amara.org subtitle credits (由 Amara.org 社群提供的字幕 and variants)
- Subtitle attributions: 中文字幕: [name], 字幕組: [name] (often celebrity names like 李宗盛)
- Outro boilerplate: 请订阅, 感谢观看, 谢谢大家, Thanks for watching
- The same line repeating verbatim across many consecutive 30-second segments
- Anything that clearly sounds like a YouTube credit rather than live sports commentary

PREFER TRANSLATING OVER BLANKING. Short utterances (好, 对, 嗯, 等一下, 跳起来), interjections, casual chatter, segment-break transitions, and closing remarks ARE legitimate content — translate them. Blanks are only for clear YouTube-artifact hallucinations."""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("language", help="Target language name, e.g. English")
    parser.add_argument("--model", default="claude-sonnet-4-6")
    parser.add_argument("--max-tokens", type=int, default=16000)
    args = parser.parse_args()

    input_text = args.input.read_text()

    client = anthropic.Anthropic()
    response = client.messages.create(
        model=args.model,
        max_tokens=args.max_tokens,
        system=[
            {
                "type": "text",
                "text": SYSTEM_PROMPT,
                "cache_control": {"type": "ephemeral"},
            }
        ],
        messages=[
            {
                "role": "user",
                "content": f"Translate the following lines to {args.language}:\n\n{input_text}",
            }
        ],
    )

    if response.stop_reason not in ("end_turn", "max_tokens"):
        sys.stderr.write(f"unexpected stop_reason={response.stop_reason}\n")
        return 2

    text = "".join(b.text for b in response.content if b.type == "text")
    args.output.write_text(text)

    u = response.usage
    sys.stderr.write(
        f"[{args.language}] in={u.input_tokens} "
        f"cache_read={u.cache_read_input_tokens} "
        f"cache_write={u.cache_creation_input_tokens} "
        f"out={u.output_tokens} stop={response.stop_reason}\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

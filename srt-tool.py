#!/usr/bin/env python3
"""SRT chunk / extract / reassemble helpers for the translation pipeline."""

import re
import sys
from pathlib import Path

ENTRY_RE = re.compile(
    r'^\s*(\d+)\s*\n([0-9:,\. \->]+-->[0-9:,\. \->]+)\s*\n(.*?)\s*$',
    re.DOTALL,
)


def parse_srt(path: Path):
    blocks = re.split(r'\n\s*\n', Path(path).read_text().strip())
    entries = []
    for block in blocks:
        m = ENTRY_RE.match(block)
        if m:
            entries.append((m.group(1), m.group(2).strip(), m.group(3).strip()))
    return entries


def write_srt(path: Path, entries):
    with open(path, 'w') as f:
        for idx, ts, content in entries:
            f.write(f'{idx}\n{ts}\n{content}\n\n')


def cmd_chunk(src, outdir, n):
    entries = parse_srt(Path(src))
    Path(outdir).mkdir(parents=True, exist_ok=True)
    for i in range(0, len(entries), n):
        out = Path(outdir) / f'chunk_{i // n:03d}.srt'
        write_srt(out, entries[i:i + n])
    print(f'{len(entries)} entries in {(len(entries) + n - 1) // n} chunks')


def cmd_extract(src, dst):
    entries = parse_srt(Path(src))
    with open(dst, 'w') as f:
        for i, (_, _, content) in enumerate(entries, 1):
            f.write(f'<<{i}>> {content.replace(chr(10), " ")}\n')


def cmd_reassemble(src, trans, dst):
    entries = parse_srt(Path(src))
    translated = {}
    for line in Path(trans).read_text().splitlines():
        m = re.match(r'^<<(\d+)>>\s*(.*)$', line)
        if m:
            translated[int(m.group(1))] = m.group(2)
    merged = [
        (idx, ts, translated.get(i, ''))
        for i, (idx, ts, _) in enumerate(entries, 1)
    ]
    write_srt(Path(dst), merged)


def main():
    cmd = sys.argv[1]
    if cmd == 'chunk':
        cmd_chunk(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif cmd == 'extract':
        cmd_extract(sys.argv[2], sys.argv[3])
    elif cmd == 'reassemble':
        cmd_reassemble(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(f'unknown command: {cmd}', file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()

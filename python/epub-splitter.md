# epub-splitter.py

Split huge EPUB (e.g. 4000+ chapters) into smaller multi-volume EPUBs.

## Setup

```
python3 -m venv .venv
source .venv/bin/activate
pip install -r epub-splitter.requirements.txt
```

## Usage

```
python3 epub-splitter.py <input.epub> (--parts N | --max-chapters N | --max-size MB) [--prefix NAME] [--output-dir DIR]
```

One split mode required, mutually exclusive:

- `--parts N` — divide chapters into N roughly equal volumes
- `--max-chapters N` — fixed max chapters per volume
- `--max-size MB` — accumulate chapters per volume until size (MB, based on chapter content) hit

Optional:

- `--prefix NAME` — output filename prefix (default: source filename without extension)
- `--output-dir DIR` — where volumes get written (default: current dir)

## Output naming

```
<prefix> - vol <NNN> - ch <AAA-BBB>.epub
```

e.g. `this is huge.epub` → `this is huge - vol 001 - ch 001-050.epub`, `this is huge - vol 002 - ch 051-100.epub`, ...

Single-volume output (e.g. `--parts 1`) skips numbering: just `<prefix>.epub`.

## What each volume contains

- Chapters = spine items, in original order, chunked per split mode
- Metadata (title, language, author) carried over per volume, title suffixed with volume number
- Per-volume TOC/nav/ncx built fresh from included chapters only
- CSS, images, and fonts included per volume only if actually referenced by that volume's chapters — shared resources deduped once per volume, not duplicated per chapter
- Fonts/images referenced only inside CSS (`url(...)`, e.g. `@font-face`) also detected and pulled in

## Notes

- Chapter = one spine item (typical for auto-generated/converted EPUBs where each chapter is its own XHTML file)
- Chapter titles taken from `<title>`, else first `<h1>/<h2>/<h3>`, else falls back to `Chapter N`
- Uses `ebooklib` for EPUB structure; reads/writes raw XHTML bytes directly to avoid ebooklib's lossy content-reconstruction (which otherwise strips `<head>`/stylesheet links on write)
- Source project (with test fixtures/history): `~/projects/personal/python/epub-splitter/`

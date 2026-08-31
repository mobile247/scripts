#!/usr/bin/env python3
"""Split a huge EPUB (many chapters) into smaller multi-volume EPUBs.

Split by number of parts, max chapters per volume, or max size (MB) per volume.
"""

import argparse
import math
import os
import re
import sys
from dataclasses import dataclass

from ebooklib import epub, ITEM_DOCUMENT, ITEM_IMAGE, ITEM_STYLE, ITEM_FONT
from bs4 import BeautifulSoup


def sanitize(name: str) -> str:
    return re.sub(r'[\\/:*?"<>|]', "_", name).strip()


def chapter_title(item, index) -> str:
    try:
        soup = BeautifulSoup(item.content, "html.parser")
        if soup.title and soup.title.string and soup.title.string.strip():
            return soup.title.string.strip()
        for tag in ("h1", "h2", "h3"):
            h = soup.find(tag)
            if h and h.get_text(strip=True):
                return h.get_text(strip=True)
    except Exception:
        pass
    return f"Chapter {index}"


def resource_refs(item):
    """Hrefs an xhtml chapter references (images, css) relative to its own path."""
    refs = set()
    try:
        soup = BeautifulSoup(item.content, "html.parser")
        for tag, attr in (("img", "src"), ("image", "href"), ("link", "href")):
            for el in soup.find_all(tag):
                v = el.get(attr) or el.get("{http://www.w3.org/1999/xlink}href")
                if v:
                    refs.add(v)
    except Exception:
        pass
    return refs


def resolve_href(base_href, ref):
    if ref.startswith(("http://", "https://", "data:")):
        return None
    base_dir = os.path.dirname(base_href)
    return os.path.normpath(os.path.join(base_dir, ref)).replace(os.sep, "/")


@dataclass
class Chapter:
    item: object
    title: str
    size: int


def load_chapters(book):
    spine_ids = [sid for sid, _ in book.spine if sid != "nav"]
    id_to_item = {item.get_id(): item for item in book.get_items_of_type(ITEM_DOCUMENT)}
    chapters = []
    for i, sid in enumerate(spine_ids, start=1):
        item = id_to_item.get(sid)
        if item is None:
            continue
        chapters.append(Chapter(item=item, title=chapter_title(item, i), size=len(item.content)))
    return chapters


def group_by_parts(chapters, parts):
    total = len(chapters)
    if parts < 1:
        raise ValueError("parts must be >= 1")
    chunk = math.ceil(total / parts)
    return group_by_max_chapters(chapters, chunk)


def group_by_max_chapters(chapters, max_chapters):
    if max_chapters < 1:
        raise ValueError("max-chapters must be >= 1")
    groups = []
    for i in range(0, len(chapters), max_chapters):
        groups.append(chapters[i:i + max_chapters])
    return groups


def group_by_max_size(chapters, max_size_bytes):
    if max_size_bytes < 1:
        raise ValueError("max-size must be >= 1")
    groups = []
    current = []
    current_size = 0
    for ch in chapters:
        if current and current_size + ch.size > max_size_bytes:
            groups.append(current)
            current = []
            current_size = 0
        current.append(ch)
        current_size += ch.size
    if current:
        groups.append(current)
    return groups


def build_volume(src_book, group, vol_num, start_num, end_num, prefix, out_dir, total_vols, total_chapters, resources_by_href):
    vol_width = max(2, len(str(total_vols)))
    ch_width = max(2, len(str(total_chapters)))

    vol = epub.EpubBook()
    vol.set_identifier(f"{src_book.get_metadata('DC', 'identifier')[0][0] if src_book.get_metadata('DC', 'identifier') else prefix}-vol{vol_num:0{vol_width}d}")

    orig_title = None
    md_title = src_book.get_metadata("DC", "title")
    if md_title:
        orig_title = md_title[0][0]
    vol.set_title(f"{orig_title or prefix} - Vol {vol_num:0{vol_width}d}")

    for lang in src_book.get_metadata("DC", "language") or [("en", {})]:
        vol.set_language(lang[0])
        break
    else:
        vol.set_language("en")

    for author in src_book.get_metadata("DC", "creator") or []:
        vol.add_author(author[0])

    new_chapter_items = []
    chapter_refs = []  # (new_item, set of resolved hrefs) per chapter
    for ch in group:
        item = ch.item
        new_item = epub.EpubHtml(
            uid=item.get_id(),
            file_name=item.get_name(),
            title=ch.title,
            lang=item.lang,
        )
        new_item.content = item.content
        vol.add_item(new_item)
        new_chapter_items.append(new_item)

        refs = set()
        for ref in resource_refs(item):
            resolved = resolve_href(item.get_name(), ref)
            if resolved:
                refs.add(resolved)
        chapter_refs.append((new_item, refs))

    needed_hrefs = set()
    for _, refs in chapter_refs:
        needed_hrefs |= refs

    added_items = {}  # href -> new EpubItem
    to_scan_for_css_refs = list(needed_hrefs)
    seen_hrefs = set(needed_hrefs)
    while to_scan_for_css_refs:
        href = to_scan_for_css_refs.pop()
        res = resources_by_href.get(href)
        if res is None or href in added_items:
            continue
        kind, orig_item = res
        new_res = epub.EpubItem(
            uid=orig_item.get_id(),
            file_name=orig_item.get_name(),
            media_type=orig_item.media_type,
            content=orig_item.get_content(),
        )
        vol.add_item(new_res)
        added_items[href] = new_res

        if kind == ITEM_STYLE:
            for url_ref in re.findall(r'url\(\s*["\']?([^"\')]+)["\']?\s*\)', orig_item.get_content().decode("utf-8", "ignore")):
                resolved = resolve_href(href, url_ref)
                if resolved and resolved not in seen_hrefs:
                    seen_hrefs.add(resolved)
                    to_scan_for_css_refs.append(resolved)

    for new_item, refs in chapter_refs:
        for href in refs:
            res_item = added_items.get(href)
            if res_item is not None and res_item.get_type() == ITEM_STYLE:
                new_item.add_item(res_item)

    vol.toc = tuple(new_chapter_items)
    vol.add_item(epub.EpubNcx())
    vol.add_item(epub.EpubNav())
    vol.spine = ["nav"] + new_chapter_items

    if total_vols > 1:
        fname = f"{prefix} - vol {vol_num:0{vol_width}d} - ch {start_num:0{ch_width}d}-{end_num:0{ch_width}d}.epub"
    else:
        fname = f"{prefix}.epub"
    out_path = os.path.join(out_dir, sanitize(fname))
    epub.write_epub(out_path, vol)
    return out_path


def main():
    parser = argparse.ArgumentParser(description="Split a large EPUB into smaller multi-volume EPUBs.")
    parser.add_argument("input", help="Path to source .epub file")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--parts", type=int, help="Split into N roughly equal volumes")
    mode.add_argument("--max-chapters", type=int, help="Max chapters per volume")
    mode.add_argument("--max-size", type=float, help="Max size (MB, based on chapter content) per volume")
    parser.add_argument("--prefix", help="Output filename prefix (default: source filename without extension)")
    parser.add_argument("--output-dir", default=".", help="Directory to write output volumes into (default: current dir)")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"error: input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    prefix = args.prefix or os.path.splitext(os.path.basename(args.input))[0]
    os.makedirs(args.output_dir, exist_ok=True)

    print(f"reading {args.input} ...")
    book = epub.read_epub(args.input, options={"ignore_ncx": True})

    resources_by_href = {}
    for kind in (ITEM_IMAGE, ITEM_STYLE, ITEM_FONT):
        for item in book.get_items_of_type(kind):
            resources_by_href[item.get_name()] = (kind, item)

    chapters = load_chapters(book)
    total = len(chapters)
    if total == 0:
        print("error: no chapters found in spine", file=sys.stderr)
        sys.exit(1)
    print(f"found {total} chapters")

    if args.parts:
        groups = group_by_parts(chapters, args.parts)
    elif args.max_chapters:
        groups = group_by_max_chapters(chapters, args.max_chapters)
    else:
        groups = group_by_max_size(chapters, int(args.max_size * 1024 * 1024))

    total_vols = len(groups)
    written = []
    idx = 0
    for vol_num, group in enumerate(groups, start=1):
        start_num = idx + 1
        idx += len(group)
        end_num = idx
        path = build_volume(book, group, vol_num, start_num, end_num, prefix, args.output_dir, total_vols, total, resources_by_href)
        written.append(path)
        print(f"  wrote {path}  ({len(group)} chapters)")

    print(f"done: {total_vols} volume(s) written to {args.output_dir}")


if __name__ == "__main__":
    main()

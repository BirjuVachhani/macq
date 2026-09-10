#!/usr/bin/env python3
"""Build the Sparkle appcast for a MacQ release.

Sparkle polls the feed at SUFeedURL and offers the newest <item> it finds, so a
release amounts to one more item: the DMG's URL, its length, its EdDSA
signature, and the release notes lifted out of CHANGELOG.md.

Items already in the published feed are carried over (pass it with --existing),
so the history survives instead of being flattened to a single release on every
run. An item for the same build number is replaced rather than duplicated, and
keeps its original pubDate, which makes re-publishing a version idempotent.

Sparkle compares releases by sparkle:version, the CFBundleVersion, so a build
number that did not move since the last release would leave everyone stuck on
what they have. That is treated as an error rather than published.
"""

from __future__ import annotations

import argparse
import html
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.dom import minidom
from xml.parsers import expat

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

# A heading like "## [0.3.0] - 2026-09-05", "## 0.3.0" or "## v0.3.0 (2026-09-05)".
HEADING_RE = re.compile(r"^##[ \t]+(?P<title>\S.*?)[ \t]*$", re.MULTILINE)
VERSION_RE = re.compile(r"\[?v?(?P<version>\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.\-]+)?)\]?")


class Failure(Exception):
    """A problem worth reporting to the release operator by name."""


# ------------------------------------------------------------------ notes ---


def release_notes(changelog: str, version: str) -> str:
    """Return the CHANGELOG.md section for `version`, heading excluded."""
    headings = list(HEADING_RE.finditer(changelog))
    seen = []
    for index, heading in enumerate(headings):
        title = heading.group("title")
        match = VERSION_RE.match(title)
        if not match:
            # "## Unreleased" and the like: not a release, but worth naming in
            # the error below only if nothing matches at all.
            continue
        found = match.group("version")
        seen.append(found)
        if found != version:
            continue
        start = heading.end()
        end = headings[index + 1].start() if index + 1 < len(headings) else len(changelog)
        return changelog[start:end].strip("\n")

    raise Failure(
        "no section for version %s in the changelog.\n"
        "       Add a '## [%s] - <date>' heading with the release notes under it.\n"
        "       Versions found: %s" % (version, version, ", ".join(seen) or "none")
    )


# ------------------------------------------------------------------- html ---


def inline(text: str) -> str:
    """Convert the inline markdown Sparkle's release notes actually use."""
    links: list[tuple[str, str]] = []

    def hold_link(match: re.Match[str]) -> str:
        # Preserve the raw pieces until their two different HTML contexts are
        # known. Escaping the whole line first and then the href again turns a
        # legitimate query-string ampersand into &amp;amp;.
        links.append(match.groups())
        return "\x00LINK%d\x00" % (len(links) - 1)

    text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", hold_link, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)

    for index, (label, url) in enumerate(links):
        rendered = '<a href="%s">%s</a>' % (
            html.escape(url, quote=True),
            html.escape(label, quote=False),
        )
        text = text.replace("\x00LINK%d\x00" % index, rendered)
    return text


def markdown_to_html(markdown: str) -> str:
    """Render a changelog section as the small subset of HTML Sparkle shows.

    Sparkle puts the description in a WebView, so this only needs headings,
    lists and paragraphs. Anything fancier is out of place in a release note.
    """
    out: list[str] = []
    paragraph: list[str] = []
    in_list = False

    def close_paragraph() -> None:
        if paragraph:
            out.append("<p>%s</p>" % inline(" ".join(paragraph)))
            paragraph.clear()

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in markdown.splitlines():
        line = raw.rstrip()
        stripped = line.strip()

        if not stripped:
            close_paragraph()
            close_list()
            continue

        heading = re.match(r"^(#{3,6})[ \t]+(.*)$", stripped)
        if heading:
            close_paragraph()
            close_list()
            level = min(len(heading.group(1)), 6)
            out.append("<h%d>%s</h%d>" % (level, inline(heading.group(2)), level))
            continue

        bullet = re.match(r"^[-*+][ \t]+(.*)$", stripped)
        if bullet:
            close_paragraph()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>%s</li>" % inline(bullet.group(1)))
            continue

        if in_list:
            # A wrapped continuation of the bullet above it.
            out[-1] = out[-1][: -len("</li>")] + " " + inline(stripped) + "</li>"
            continue

        paragraph.append(stripped)

    close_paragraph()
    close_list()
    return "\n".join(out)


def cdata(text: str) -> str:
    """Escape the one sequence a CDATA section cannot hold."""
    return text.replace("]]>", "]]]]><![CDATA[>")


# -------------------------------------------------------------- existing ---



def reject_unsafe_xml(source: bytes) -> None:
    """Reject every DTD/entity path before minidom parses network input.

    Expat understands the XML declaration and BOM itself, so this covers UTF-8,
    UTF-16 and every encoding the actual parser accepts. A byte search for
    ``<!DOCTYPE`` does not. Appcasts need neither DTDs nor custom entities.
    """
    parser = expat.ParserCreate()

    def forbidden(*_args: object) -> None:
        raise Failure("the existing appcast contains a forbidden DTD or entity")

    parser.StartDoctypeDeclHandler = forbidden
    parser.EntityDeclHandler = forbidden
    parser.UnparsedEntityDeclHandler = forbidden
    parser.ExternalEntityRefHandler = forbidden
    try:
        parser.Parse(source, True)
    except Failure:
        raise
    except expat.ExpatError as error:
        raise Failure("the existing appcast is not valid XML: %s" % error)

def item_build(item: minidom.Element) -> int | None:
    """The sparkle:version of an existing item, as an element or an attribute."""
    for node in item.getElementsByTagNameNS(SPARKLE_NS, "version"):
        text = "".join(c.data for c in node.childNodes if c.nodeType == c.TEXT_NODE)
        if text.strip().isdigit():
            return int(text.strip())
    for enclosure in item.getElementsByTagName("enclosure"):
        value = enclosure.getAttributeNS(SPARKLE_NS, "version")
        if value.strip().isdigit():
            return int(value.strip())
    return None


def item_short_version(item: minidom.Element) -> str | None:
    """The human-facing version of an existing item."""
    for node in item.getElementsByTagNameNS(SPARKLE_NS, "shortVersionString"):
        text = "".join(c.data for c in node.childNodes if c.nodeType == c.TEXT_NODE)
        if text.strip():
            return text.strip()
    for enclosure in item.getElementsByTagName("enclosure"):
        value = enclosure.getAttributeNS(SPARKLE_NS, "shortVersionString")
        if value.strip():
            return value.strip()
    return None


def item_signature(item: minidom.Element) -> str | None:
    """The EdDSA signature for the existing release's enclosure."""
    for enclosure in item.getElementsByTagName("enclosure"):
        value = enclosure.getAttributeNS(SPARKLE_NS, "edSignature")
        if value.strip():
            return value.strip()
    return None


def item_pub_date(item: minidom.Element) -> str | None:
    for node in item.getElementsByTagName("pubDate"):
        text = "".join(c.data for c in node.childNodes if c.nodeType == c.TEXT_NODE)
        if text.strip():
            return text.strip()
    return None


def existing_items(path: str, build: int, version: str, signature: str) -> tuple[list[str], str | None]:
    """Return prior items as XML text, plus the pubDate of the one replaced."""
    try:
        with open(path, "rb") as handle:
            source = handle.read()
        # The published feed is network input. Strictly parse it once with
        # every DTD/entity callback forbidden before building a DOM from the
        # same unchanged bytes.
        reject_unsafe_xml(source)
        document = minidom.parseString(source)
    except Failure:
        raise
    except Exception as error:  # a truncated download, or something not XML
        raise Failure("could not read the existing appcast %s: %s" % (path, error))

    kept: list[str] = []
    replaced_date: str | None = None
    for item in document.getElementsByTagName("item"):
        other = item_build(item)
        if other == build:
            previous_version = item_short_version(item)
            if previous_version != version:
                raise Failure(
                    "the published feed already uses build %d for version %s, and this release is\n"
                    "       version %s with the same build. Sparkle compares builds, so it would\n"
                    "       never offer this update. Bump CURRENT_PROJECT_VERSION\n"
                    "       (./set_version.sh %s ++)."
                    % (build, previous_version or "(unknown)", version, version)
                )
            previous_signature = item_signature(item)
            if previous_signature != signature:
                raise Failure(
                    "the published feed already uses version %s build %d for different DMG bytes.\n"
                    "       Rebuilding in place would make the cached DMG disagree with its\n"
                    "       appcast signature. Bump the build number instead\n"
                    "       (./set_version.sh %s ++)."
                    % (version, build, version)
                )
            replaced_date = item_pub_date(item)
            continue
        if other is not None and other > build:
            raise Failure(
                "the published feed already offers build %d, and this release is\n"
                "       build %d. Sparkle compares builds, so publishing this would strand\n"
                "       everyone on %d. Bump CURRENT_PROJECT_VERSION (./set_version.sh"
                " <version> ++)." % (other, build, other)
            )
        kept.append(item.toxml())
    return kept, replaced_date


# ----------------------------------------------------------------- output ---

DOCUMENT = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>{title}</title>
    <link>{feed_url}</link>
    <description>Updates for {title}.</description>
    <language>en</language>
{items}
  </channel>
</rss>
"""

ITEM = """    <item>
      <title>{title} {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system_version}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes}
]]></description>
      <enclosure url="{url}"
                 length="{length}"
                 type="application/octet-stream"
                 sparkle:edSignature="{signature}" />
    </item>"""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="marketing version, e.g. 0.3.0")
    parser.add_argument("--build", type=int, help="CFBundleVersion")
    parser.add_argument("--url", help="public download URL of the DMG")
    parser.add_argument("--length", type=int, help="DMG size in bytes")
    parser.add_argument("--signature", help="Sparkle EdDSA signature")
    parser.add_argument("--changelog", required=True, help="path to CHANGELOG.md")
    parser.add_argument("--output", help="appcast.xml to write")
    parser.add_argument("--feed-url", help="public URL of the appcast")
    parser.add_argument("--min-system-version", help="e.g. 14.0")
    parser.add_argument("--check-changelog", action="store_true",
                        help="validate this version's release notes, then stop")
    parser.add_argument("--title", default="MacQ", help="channel title")
    parser.add_argument("--existing", help="the currently published appcast, to merge into")
    args = parser.parse_args(argv)

    with open(args.changelog, encoding="utf-8") as handle:
        changelog = handle.read()

    notes = markdown_to_html(release_notes(changelog, args.version))
    if not notes.strip():
        raise Failure("the changelog section for %s is empty." % args.version)
    if args.check_changelog:
        print("    %s has release notes for %s" % (args.changelog, args.version))
        return 0

    required = {
        "--build": args.build,
        "--url": args.url,
        "--length": args.length,
        "--signature": args.signature,
        "--output": args.output,
        "--feed-url": args.feed_url,
        "--min-system-version": args.min_system_version,
    }
    missing = [name for name, value in required.items() if value is None]
    if missing:
        parser.error("the following arguments are required unless --check-changelog is used: %s"
                     % ", ".join(missing))

    kept: list[str] = []
    pub_date = None
    if args.existing:
        kept, pub_date = existing_items(args.existing, args.build, args.version, args.signature)

    item = ITEM.format(
        title=html.escape(args.title),
        version=html.escape(args.version),
        build=args.build,
        pub_date=html.escape(pub_date or format_datetime(datetime.now(timezone.utc))),
        min_system_version=html.escape(args.min_system_version),
        notes=cdata(notes),
        url=html.escape(args.url, quote=True),
        length=args.length,
        signature=html.escape(args.signature, quote=True),
    )

    items = "\n".join([item] + ["    " + text for text in kept])
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(DOCUMENT.format(title=html.escape(args.title),
                                     feed_url=html.escape(args.feed_url),
                                     items=items))

    print("    %s: %s (%d), %d byte enclosure, %d earlier release(s) kept"
          % (args.output, args.version, args.build, args.length, len(kept)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Failure as failure:
        print("error: %s" % failure, file=sys.stderr)
        sys.exit(1)

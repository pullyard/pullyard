#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "brand.json"
MAC = ROOT / "Sources/PullYard/Shared/Theme.swift"
WIN = ROOT / "windows/src/PullYard.Core/Theming/ThemeTokens.cs"
LINUX = ROOT / "linux/src/theme.rs"

MAC_RE = re.compile(r'(static let sy\w+ = Theme\.color\("(\w+)", light: 0x)([0-9A-Fa-f]{6})(, dark: 0x)([0-9A-Fa-f]{6})(?:(, lightAlpha: )([\d.]+)(, darkAlpha: )([\d.]+))?')
WIN_RE = re.compile(r'^(\s*\["(\w+)"\] = )(Solid|Same|new)\((.*)\),\s*$')
WIN_ARG = re.compile(r'WithOpacity\(0x([0-9A-Fa-f]{6}), ([\d.]+)\)|0x([0-9A-Fa-f]{6,8})u?')
LINUX_RE = re.compile(r'\("(\w+)", "(alpha\()?#([0-9A-Fa-f]{6})(?:, ([\d.]+)\))?"\)')


def camel(snake):
    head, *rest = snake.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def snake(name):
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name).lower()


def norm_alpha(a):
    return None if a is None or float(a) >= 1 else round(float(a), 3)


def mac_tokens():
    out = {}
    for m in MAC_RE.finditer(MAC.read_text()):
        out[m.group(2)] = {"light": "#" + m.group(3).upper(), "dark": "#" + m.group(5).upper(), "lightAlpha": norm_alpha(m.group(7)), "darkAlpha": norm_alpha(m.group(9))}
    return out


def parse_win_arg(m):
    if m.group(1):
        return "#" + m.group(1).upper(), norm_alpha(m.group(2))
    raw = m.group(3).upper()
    if len(raw) == 8:
        return "#" + raw[2:], norm_alpha(int(raw[:2], 16) / 255)
    return "#" + raw, None


def win_tokens():
    out = {}
    if not WIN.exists():
        return out
    for line in WIN.read_text().splitlines():
        m = WIN_RE.match(line)
        if not m:
            continue
        args = list(WIN_ARG.finditer(m.group(4)))
        if not args:
            continue
        light = parse_win_arg(args[0])
        dark = light if m.group(3) == "Same" or len(args) < 2 else parse_win_arg(args[1])
        out[m.group(2)] = {"light": light[0], "dark": dark[0], "lightAlpha": light[1], "darkAlpha": dark[1]}
    return out


def linux_blocks(text):
    blocks = {}
    for mode, marker in (("light", "const BRAND_LIGHT"), ("dark", "const BRAND_DARK")):
        start = text.find(marker)
        if start < 0:
            continue
        end = text.find("};", start)
        blocks[mode] = (start, end)
    return blocks


def linux_tokens():
    out = {}
    if not LINUX.exists():
        return out
    text = LINUX.read_text()
    for mode, (start, end) in linux_blocks(text).items():
        for m in LINUX_RE.finditer(text, start, end):
            entry = out.setdefault(camel(m.group(1)), {})
            entry[mode] = "#" + m.group(3).upper()
            entry[mode + "Alpha"] = norm_alpha(m.group(4))
    return out


def load_brand():
    data = json.loads(BRAND.read_text())
    return {name: {"light": t["light"].upper(), "dark": t["dark"].upper(), "lightAlpha": norm_alpha(t.get("lightAlpha")), "darkAlpha": norm_alpha(t.get("darkAlpha"))} for name, t in data["colors"].items()}


def describe(t):
    def one(hex_, a):
        return hex_ + (f"@{a}" if a is not None else "")
    return f"{one(t.get('light'), t.get('lightAlpha'))} / {one(t.get('dark'), t.get('darkAlpha'))}"


def diff(brand, platform):
    out = []
    for name, want in brand.items():
        have = platform.get(name)
        if have is None:
            continue
        if any(have.get(k) != want[k] for k in ("light", "dark", "lightAlpha", "darkAlpha")):
            out.append((name, describe(want), describe(have)))
    return out


def cmd_extract(_):
    tokens = mac_tokens()
    data = {"name": "PullYard", "source": "Sources/PullYard/Shared/Theme.swift", "colors": {}}
    for name, t in tokens.items():
        entry = {"light": t["light"], "dark": t["dark"]}
        if t["lightAlpha"] is not None:
            entry["lightAlpha"] = t["lightAlpha"]
        if t["darkAlpha"] is not None:
            entry["darkAlpha"] = t["darkAlpha"]
        data["colors"][name] = entry
    BRAND.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Wrote {len(tokens)} colors to {BRAND.relative_to(ROOT)}")
    return 0


def cmd_check(args):
    brand = load_brand()
    platforms = {"macos": mac_tokens(), "windows": win_tokens(), "linux": linux_tokens()}
    failed = False
    for name, tokens in platforms.items():
        if args.platform and name not in args.platform:
            continue
        drift = diff(brand, tokens)
        shared = sum(1 for k in brand if k in tokens)
        print(f"{name}: {shared} shared colors, {len(drift)} differ")
        for token, want, have in drift:
            print(f"  {token}: brand {want}, {name} {have}")
        failed = failed or bool(drift)
    return 1 if failed and args.strict else 0


def fmt_alpha(a):
    return f"{a:.2f}" if a is not None else None


def apply_mac(brand):
    text = MAC.read_text()

    def repl(m):
        t = brand.get(m.group(2))
        if not t:
            return m.group(0)
        s = m.group(1) + t["light"][1:] + m.group(4) + t["dark"][1:]
        if m.group(6):
            s += m.group(6) + (f"{t['lightAlpha']:.2f}" if t["lightAlpha"] is not None else "1") + m.group(8) + (f"{t['darkAlpha']:.2f}" if t["darkAlpha"] is not None else "1")
        return s

    new = MAC_RE.sub(repl, text)
    MAC.write_text(new)
    return new != text


def apply_linux(brand):
    text = LINUX.read_text()
    parts = []
    last = 0
    for mode, (start, end) in sorted(linux_blocks(text).items(), key=lambda x: x[1][0]):
        parts.append(text[last:start])

        def repl(m, mode=mode):
            t = brand.get(camel(m.group(1)))
            if not t:
                return m.group(0)
            hex_, a = t[mode], t[mode + "Alpha"]
            if m.group(2) or a is not None:
                return f'("{m.group(1)}", "alpha({hex_}, {fmt_alpha(a) or "1"})")'
            return f'("{m.group(1)}", "{hex_}")'

        parts.append(LINUX_RE.sub(repl, text[start:end]))
        last = end
    parts.append(text[last:])
    new = "".join(parts)
    LINUX.write_text(new)
    return new != text


def apply_windows(brand):
    lines = WIN.read_text().splitlines(keepends=True)
    changed = False
    for i, line in enumerate(lines):
        m = WIN_RE.match(line.rstrip("\n"))
        if not m or m.group(3) != "Solid":
            continue
        t = brand.get(m.group(2))
        if not t or t["lightAlpha"] is not None or t["darkAlpha"] is not None:
            continue
        args = list(WIN_ARG.finditer(m.group(4)))
        if len(args) < 2 or args[0].group(3) is None or args[1].group(3) is None:
            continue
        body = m.group(4)
        body = body[:args[1].start()] + "0x" + t["dark"][1:] + body[args[1].end():]
        body = body[:args[0].start()] + "0x" + t["light"][1:] + body[args[0].end():]
        new = f"{m.group(1)}Solid({body}),\n"
        if new != line:
            lines[i] = new
            changed = True
    WIN.write_text("".join(lines))
    return changed


def cmd_apply(args):
    brand = load_brand()
    targets = args.platform or ["macos"]
    for name in targets:
        fn = {"macos": apply_mac, "windows": apply_windows, "linux": apply_linux}[name]
        print(f"{name}: {'updated' if fn(brand) else 'already matches'}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Keep PullYard colors in one place: brand.json")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("extract", help="write brand.json from the macOS theme").set_defaults(fn=cmd_extract)
    check = sub.add_parser("check", help="compare every platform with brand.json")
    check.add_argument("--platform", action="append", choices=["macos", "windows", "linux"])
    check.add_argument("--strict", action="store_true", help="exit 1 when any platform differs")
    check.set_defaults(fn=cmd_check)
    apply = sub.add_parser("apply", help="write brand.json colors into platform themes")
    apply.add_argument("--platform", action="append", choices=["macos", "windows", "linux"])
    apply.set_defaults(fn=cmd_apply)
    args = parser.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()

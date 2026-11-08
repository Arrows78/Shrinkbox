#!/usr/bin/env python3
"""Fails when a user-facing English text has no French translation, or when fr.lproj has duplicate keys.

Checks the literals handed to L("..."), Text, Button, Label, Toggle, Section, TextField, Stepper and Picker.
Interpolated literals are checked by their SwiftUI key (\\(x) becomes %lld or %@ and must be listed by hand).
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
fr_text = (root / "Resources/fr.lproj/Localizable.strings").read_text()
fr_keys = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', fr_text, re.M)
errors = [f"duplicate key in fr.lproj: {k}" for k in sorted({k for k in fr_keys if fr_keys.count(k) > 1})]
known = set(fr_keys)

# Other languages are generated from scripts/data/translations.tsv: they must hold exactly the French keys.
for lang in ("es", "de"):
    f = root / f"Resources/{lang}.lproj/Localizable.strings"
    if not f.exists():
        errors.append(f"{lang}.lproj is missing (run scripts/gen_lproj.py)"); continue
    keys = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', f.read_text(), re.M))
    for k in sorted(known - keys): errors.append(f"{lang}: no translation for \"{k}\" (add it to scripts/data/translations.tsv, run scripts/gen_lproj.py)")
    for k in sorted(keys - known): errors.append(f"{lang}: unknown key \"{k}\"")

# Literals that are not words to translate: symbols, units, code, brand names.
ignore = {"", "x", "·", "…", "C", "D", "F", "O", "P", "audio", "video", "shrinkbox.audio", "MCP"}
# The command line speaks English: its usage and syntax errors are not translated.
cli_only = ("Usage:", "Give ", "--size is required", "Expected key", "capFps needs", "changeSpeed needs", "lowerBitrate needs", "crop needs", "downscale needs",
            "A pipeline named", "A zone with this name", "No saved pipeline with this name", "Unknown step", "%@ needs", "%@ is needed %@")
pat = re.compile(r'\b(?:L|Text|Button|Label|Toggle|Section|TextField|Stepper|Picker|Slider|accessibilityLabel|SettingsToggle|SettingsNote|help)\(\s*"((?:[^"\\]|\\.)*)"'
                 r'|\b(?:title|subtitle|label):\s*"((?:[^"\\]|\\.)*)"'
                 r'|CropPreset\(name:\s*"((?:[^"\\]|\\.)*)"')
# The settings catalogue: add("key", "Title", group:, section: "…", …, help: "…") is shown through LocalizedStringKey.
catalogue = re.compile(r'add\("[^"]+",\s*"((?:[^"\\]|\\.)*)",\s*group:\s*"[^"]*",\s*section:\s*"((?:[^"\\]|\\.)*)"(?:.*?help:\s*"((?:[^"\\]|\\.)*)")?')
# Titles of the settings panes: `case .images: "Images"`.
panes = re.compile(r'case \.\w+: "((?:[^"\\]|\\.)*)"$', re.M)
used = set()
for f in sorted((root / "Sources/Shrinkbox").glob("*.swift")):
    if f.name in ("SelfTest.swift",):
        continue
    text = f.read_text()
    found = [next(g for g in m.groups() if g is not None) for m in pat.finditer(text)]
    if f.name == "Settings.swift":
        for m in catalogue.finditer(text): found += [g for g in m.groups() if g is not None]
    if f.name == "SettingsKit.swift":
        found += panes.findall(text.split("var group:")[0])
    for key in found:
        if "\\(" in key:
            continue   # interpolated: listed manually, see header
        used.add(key)
        if key not in known and key not in ignore and not key.startswith(cli_only) and not re.fullmatch(r"[\W\d_]*", key) and not key.startswith("="):
            errors.append(f"{f.name}: no French translation for \"{key}\"")

for e in errors:
    print("l10n:", e)
print(f"l10n: {len(known)} French strings, {len(used)} literals checked, {len(errors)} problem(s)")
sys.exit(1 if errors else 0)

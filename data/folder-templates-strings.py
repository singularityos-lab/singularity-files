#!/usr/bin/env python3
import json
import sys

FIELDS = ("name", "summary", "folder-name")


def c_quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def render(json_path):
    with open(json_path, encoding="utf-8") as f:
        data = json.load(f)
    seen = []
    for template in data.get("templates", []):
        for field in FIELDS:
            value = template.get(field)
            if isinstance(value, str) and value and value not in seen:
                seen.append(value)
    return "".join("N_(%s);\n" % c_quote(value) for value in seen)


def main(argv):
    check = "--check" in argv
    paths = [a for a in argv if a != "--check"]
    if len(paths) != 2:
        sys.stderr.write("usage: folder-templates-strings.py [--check] TEMPLATES.json OUTPUT.h\n")
        return 2
    expected = render(paths[0])
    if check:
        try:
            with open(paths[1], encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != expected:
            sys.stderr.write("%s is out of date, regenerate it with %s %s %s\n"
                             % (paths[1], sys.argv[0], paths[0], paths[1]))
            return 1
        return 0
    with open(paths[1], "w", encoding="utf-8") as f:
        f.write(expected)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

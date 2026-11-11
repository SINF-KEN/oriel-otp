#!/usr/bin/env python3
#
# Checks that every translation in the string catalogs (*.xcstrings) uses its key's format arguments with the same
# types. The key is what the code formats: String(localized:) turns "\(count) accounts" into "%lld accounts" and passes
# the count as an Int. A translation that reads an argument as another type (%@ for an Int) or reads one the code
# doesn't pass crashes the app or shows garbage, and nothing else catches it before it ships.
#
# A translation may leave an argument out, as a plural's "one" form often does ("One account"), and may reorder them
# with positional specifiers (%2$@). It may not mix positional and plain specifiers, which reads the wrong argument,
# use a * width or precision, which reads an argument of its own, use %n, which writes to memory, or contain a %
# that isn't a known specifier.
#
# Usage: tools/check-format-specifiers.py [catalog.xcstrings ...]   (default: every catalog in the repository)
# Exits with 1 and lists the problems if there are any.

import json
import re
import subprocess
import sys

# %%, a substitution (%#@name@), or a printf specifier with an optional position, flags, width, precision and length.
SPECIFIER = re.compile(
    r"%(?:(?P<percent>%)"
    r"|#@(?P<substitution>[A-Za-z0-9_]+)@"
    r"|(?P<position>[0-9]+\$)?[-+ #0']*(?P<width>[0-9]+|\*)?(?:\.(?P<precision>[0-9]+|\*))?"
    r"(?P<length>hh|h|ll|l|q|L|z|t|j)?(?P<conversion>[@dDiuUxXoOfFeEgGaAcCsSpn]))"
)
# Inside a substitution's variations, %arg stands for the substitution's own argument.
SUBSTITUTION_ARGUMENT = "%arg"


def argument_type(length, conversion):
    """The kind of value a specifier reads, spelled as one canonical specifier so that equivalent spellings (%d and %i,
    %f and %g) compare equal."""
    if conversion == "@":
        return "%@"
    if conversion in "dDiuUxXoOcC":
        # Swift passes Int as a 64-bit integer; %d reads 32 bits, so the length matters.
        return f"%{length or ''}d"
    if conversion in "fFeEgGaA":
        return "%f"
    if conversion in "sS":
        return "%s"
    return "%p"


def arguments(text, substitutions=None):
    """Maps each argument position text reads to its type. Raises ValueError for text that can't be read."""
    result = {}
    next_position = 1
    styles = set()

    # Every % must start a specifier this script knows, or it reads an argument nobody checked.
    position_in_text = 0
    for match in SPECIFIER.finditer(text):
        if "%" in text[position_in_text:match.start()]:
            raise ValueError(f"unknown format sequence near {text[position_in_text:match.start()]!r}")
        position_in_text = match.end()
    if "%" in text[position_in_text:]:
        raise ValueError(f"unknown format sequence near {text[position_in_text:]!r}")

    def add(position, kind):
        if result.get(position, kind) != kind:
            raise ValueError(f"argument {position} is read as both {result[position]} and {kind}")
        result[position] = kind

    for match in SPECIFIER.finditer(text):
        if match["percent"]:
            continue
        if match["substitution"]:
            name = match["substitution"]
            substitution = (substitutions or {}).get(name)
            if substitution is None:
                raise ValueError(f"%#@{name}@ has no substitution")
            spec = SPECIFIER.fullmatch("%" + substitution.get("formatSpecifier", ""))
            if spec is None or not spec["conversion"]:
                raise ValueError(f"substitution {name} has an unknown formatSpecifier")
            position = substitution.get("argNum", next_position)
            add(position, argument_type(spec["length"], spec["conversion"]))
            next_position = position + 1
            continue
        if match["conversion"] == "n":
            raise ValueError("%n writes to memory")
        if match["width"] == "*" or match["precision"] == "*":
            raise ValueError("a * width or precision reads an argument of its own")
        styles.add("positional" if match["position"] else "plain")
        if len(styles) > 1:
            raise ValueError("positional and plain specifiers are mixed")
        if match["position"]:
            position = int(match["position"][:-1])
        else:
            position = next_position
        add(position, argument_type(match["length"], match["conversion"]))
        next_position = position + 1
    return result


def string_units(node, path):
    """Yields (path, value) for every string in a localization, through plural and device variations."""
    unit = node.get("stringUnit")
    if unit is not None:
        yield path, unit.get("value", "")
    for kind, cases in node.get("variations", {}).items():
        for case, child in cases.items():
            yield from string_units(child, f"{path} {kind}.{case}")


def check(path):
    with open(path, encoding="utf-8") as file:
        catalog = json.load(file)
    problems = []
    for key, entry in catalog.get("strings", {}).items():
        try:
            expected = arguments(key)
        except ValueError as error:
            problems.append(f"{path}: key {key!r}: {error}")
            continue
        for language, localization in entry.get("localizations", {}).items():
            substitutions = localization.get("substitutions", {})
            found = []
            try:
                for where, value in string_units(localization, language):
                    found.append((where, arguments(value, substitutions)))
                for name, substitution in substitutions.items():
                    position = substitution.get("argNum")
                    spec = SPECIFIER.fullmatch("%" + substitution.get("formatSpecifier", ""))
                    kind = argument_type(spec["length"], spec["conversion"]) if spec and spec["conversion"] else None
                    for where, value in string_units(substitution, f"{language} substitution {name}"):
                        own = arguments(value.replace(SUBSTITUTION_ARGUMENT, ""))
                        if SUBSTITUTION_ARGUMENT in value and position is not None and kind is not None:
                            own.setdefault(position, kind)
                        found.append((where, own))
            except ValueError as error:
                problems.append(f"{path}: {key!r} [{language}]: {error}")
                continue
            for where, actual in found:
                for position, kind in sorted(actual.items()):
                    if position not in expected:
                        problems.append(
                            f"{path}: {key!r} [{where}]: reads argument {position}, which the key doesn't have"
                        )
                    elif expected[position] != kind:
                        problems.append(
                            f"{path}: {key!r} [{where}]: reads argument {position} as {kind}, "
                            f"the key passes {expected[position]}"
                        )
    return problems


def main():
    paths = sys.argv[1:]
    if not paths:
        listed = subprocess.run(["git", "ls-files", "*.xcstrings"], capture_output=True, text=True, check=True)
        paths = listed.stdout.split()
    if not paths:
        print("No string catalogs found.", file=sys.stderr)
        return 1
    problems = [problem for path in paths for problem in check(path)]
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} format specifier problem(s) in the translations.", file=sys.stderr)
        return 1
    print(f"Format specifiers match in {len(paths)} string catalog(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

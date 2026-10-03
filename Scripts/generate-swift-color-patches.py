#!/usr/bin/env python3
"""Generate the six QC colour patch definitions from the public schema fixture.

Run with --check to compare with the committed Swift definitions. The generated
header preserves the original probe provenance; no private framework is needed.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

DEFAULT_SCHEMA = os.path.join(REPO, "docs", "verification", "fixtures", "qc-color-generation-schema.json")
DEFAULT_OUTPUT = os.path.join(REPO, "Sources", "Graph", "QuartzComposerColorPatches.swift")

# Which registry entries to emit, and the one thing the framework cannot tell us: which
# executor implements the behaviour. `ranges` fills in slider bounds, because Quartz
# Composer does not publish QCPortAttributeMinimum/MaximumValueKey for these ports; the
# values are its inspector's, chosen to match the observed arithmetic (a luminosity factor
# above 1 is meaningful and clamps, so the range reaches 2).
PATCHES = [
    {
        "registry": "QCColorMixer",
        "id": "color-mixer",
        "executor": "qcColorMixer",
        "category": "processing",
        "ranges": {"inputMix": (0, 1)},
    },
    {
        "registry": "QCColorToComponents:hsl",
        "id": "color-to-hsl",
        "executor": "qcColorToComponentsHSL",
        "category": "processing",
        "ranges": {},
    },
    {
        "registry": "QCColorToComponents:rgb",
        "id": "color-to-rgb",
        "executor": "qcColorToComponentsRGB",
        "category": "processing",
        "ranges": {},
    },
    {
        "registry": "QCColorTransform",
        "id": "color-transformation",
        "executor": "qcColorTransform",
        "category": "processing",
        "ranges": {
            "inputHue": (-360, 360),
            "inputSaturation": (0, 2),
            "inputLuminosity": (0, 2),
            "inputAlpha": (0, 2),
        },
    },
    {
        "registry": "QCColorFromComponents:hsl",
        "id": "hsl-color",
        "executor": "qcColorFromComponentsHSL",
        "category": "input",
        "ranges": {
            "input1": (0, 1),
            "input2": (0, 1),
            "input3": (0, 1),
            "inputAlpha": (0, 1),
        },
    },
    {
        "registry": "QCColorFromComponents:rgb",
        "id": "rgb-color",
        "executor": "qcColorFromComponentsRGB",
        "category": "input",
        "ranges": {
            "input1": (0, 1),
            "input2": (0, 1),
            "input3": (0, 1),
            "inputAlpha": (0, 1),
        },
    },
]

# QCPortType… -> (PortDataType case, ParameterSchema family)
PORT_TYPES = {
    "QCPortTypeColor": ("color", "color"),
    "QCPortTypeNumber": ("number", "number"),
    "QCPortTypeBoolean": ("boolean", "boolean"),
    "QCPortTypeString": ("string", "string"),
}


def swift_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def number(value) -> str:
    """A Swift Double literal. QC defaults come back as float32, so 1 reads 0.99999994."""
    value = float(value)
    rounded = round(value, 6)
    if rounded == int(rounded) and abs(rounded) < 1e15:
        return str(int(rounded))
    return repr(rounded)


def swift_range(bounds) -> str:
    low, high = bounds
    low_text = number(low)
    if low_text.startswith("-"):
        low_text = f"({low_text})"
    return f"{low_text}...{number(high)}"


def color_literal(value) -> str:
    return (
        ".color(red: {}, green: {}, blue: {}, alpha: {})".format(
            number(value.get("red", 0)),
            number(value.get("green", 0)),
            number(value.get("blue", 0)),
            number(value.get("alpha", 1)),
        )
    )


def ordered(ports: dict) -> list[tuple[str, dict]]:
    """Ports in the order Quartz Composer enumerates them, not alphabetical order."""
    return sorted(ports.items(), key=lambda item: item[1].get("order", 1 << 30))


def selected_menu(port: dict) -> list[str]:
    """Menu labels without the display-only `-` separators, which occupy no index."""
    return [item for item in port.get("menu", []) if item != "-"]


def emit_patch(config: dict, entry: dict) -> str:
    attributes = entry.get("attributes", {})
    display_name = attributes.get("name", entry["name"])
    summary = attributes.get("description", "")
    ranges = config["ranges"]

    ports: list[str] = []
    parameters: list[str] = []

    for key, port in ordered(entry["ports"]["inputs"]):
        if port.get("system"):
            continue
        port_type = port.get("QCPortAttributeTypeKey")
        name = port.get("name", key)
        menu = selected_menu(port) if port.get("menu") else []

        if menu:
            # An index port with a menu is an inspector control, not a connection point —
            # the same treatment `qc.interpolation` gives its Curve and Repeat menus.
            default_index = int(port.get("QCPortAttributeDefaultValueKey", 0) or 0)
            default_index = min(max(default_index, 0), len(menu) - 1)
            choices = ", ".join(swift_string(item) for item in menu)
            parameters.append(
                "                .choice(\n"
                f"                    key: {swift_string(key)}, name: {swift_string(name)},\n"
                f"                    defaultValue: {swift_string(menu[default_index])},\n"
                f"                    choices: [{choices}]),"
            )
            continue

        kinds = PORT_TYPES.get(port_type)
        if kinds is None:
            print(
                f"  warning: {entry['name']} port {key} has no public type "
                f"({port.get('baseClass')}); skipped",
                file=sys.stderr,
            )
            continue
        data_type, family = kinds
        ports.append(f"                input({swift_string(key)}, {swift_string(name)}, .{data_type}),")

        default = port.get("QCPortAttributeDefaultValueKey")
        if family == "color":
            parameters.append(
                "                .color(\n"
                f"                    key: {swift_string(key)}, name: {swift_string(name)},\n"
                f"                    defaultValue: {color_literal(default or {})}),"
            )
        elif family == "number":
            bounds = ranges.get(key)
            range_text = f", range: {swift_range(bounds)}" if bounds else ""
            parameters.append(
                "                .number(\n"
                f"                    key: {swift_string(key)}, name: {swift_string(name)}, "
                f"defaultValue: {number(default if default is not None else 0)}{range_text}),"
            )
        elif family == "boolean":
            parameters.append(
                f"                .boolean(\n"
                f"                    key: {swift_string(key)}, name: {swift_string(name)}, "
                f"defaultValue: {'true' if default else 'false'}),"
            )
        else:
            parameters.append(
                "                .string(\n"
                f"                    key: {swift_string(key)}, name: {swift_string(name)}, "
                f"defaultValue: {swift_string(str(default or ''))}),"
            )

    for key, port in ordered(entry["ports"]["outputs"]):
        port_type = port.get("QCPortAttributeTypeKey")
        kinds = PORT_TYPES.get(port_type)
        if kinds is None:
            print(
                f"  warning: {entry['name']} output {key} has no public type; skipped",
                file=sys.stderr,
            )
            continue
        ports.append(
            f"                output({swift_string(key)}, {swift_string(port.get('name', key))}, "
            f".{kinds[0]}),"
        )

    body = [
        "        PatchDefinition(",
        f'            id: "\\(namespace).qc.{config["id"]}",',
        f"            name: {swift_string(display_name)},",
        f"            category: .{config['category']},",
        f"            summary: {swift_string(summary)},",
        "            ports: [",
        *ports,
        "            ],",
        "            parameters: [",
        *parameters,
        "            ],",
        f"            executorKind: .{config['executor']}",
        "        ),",
    ]
    return "\n".join(body)


def build(schema_path: str) -> str:
    with open(schema_path) as handle:
        schema = json.load(handle)

    by_registry = {entry["name"]: entry for entry in schema["patches"]}

    blocks = []
    for config in PATCHES:
        entry = by_registry.get(config["registry"])
        if entry is None:
            raise SystemExit(
                f"error: {config['registry']} is not in {schema_path}\n"
                "       recollect the reference with: qcgather.sh builtin-ports"
            )
        blocks.append(emit_patch(config, entry))

    header = f'''// Generated by Documentation/qcgather/generate-swift-color-patches.py — do not edit.
//
// Source: Documentation/qc-reference/meta/builtin-ports.json
//         Quartz Composer 4.6.2 (framework 5.1, build 370), read from live patch instances
//         by `qcgather builtin-ports` — not from documentation or from a saved .qtz.
//
// The six `Utility > Color` patches. Port keys, display names, defaults and menu entries are
// Quartz Composer's own, so a composition's published ports map onto these definitions
// without a translation table. Behaviour is not generated: each patch names the
// `PatchExecutorKind` implemented in `GraphRuntime` and `QCColorMath`.

import Foundation

extension PatchRegistry {{
    /// Quartz Composer's `Utility > Color` patches.
    static let quartzComposerColorPatches: [PatchDefinition] = [
{chr(10).join(blocks)}
    ]
}}
'''
    return header


def format_swift(source: str) -> str:
    """Run the repository's swift-format over the output.

    `Scripts/verify.sh` lints Sources with `swift-format lint --strict`, so generated code
    has to satisfy the same configuration as hand-written code. Formatting here instead of
    by hand is what keeps `--check` meaningful.
    """
    configuration = os.path.join(REPO, ".swift-format")
    try:
        result = subprocess.run(
            ["xcrun", "swift-format", "format", "--configuration", configuration, "-"],
            input=source,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("warning: xcrun not found; emitting unformatted Swift", file=sys.stderr)
        return source
    if result.returncode != 0:
        print(
            "warning: swift-format failed; emitting unformatted Swift\n" + result.stderr,
            file=sys.stderr,
        )
        return source
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", nargs="?", default=DEFAULT_SCHEMA)
    parser.add_argument("-o", "--output", default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if the output file differs from what would be generated",
    )
    parser.add_argument(
        "--no-format",
        action="store_true",
        help="skip swift-format, to inspect the raw emission",
    )
    args = parser.parse_args()

    generated = build(args.schema)
    if not args.no_format:
        generated = format_swift(generated)

    if args.check:
        try:
            with open(args.output) as handle:
                current = handle.read()
        except FileNotFoundError:
            print(f"stale: {args.output} does not exist", file=sys.stderr)
            return 1
        if current != generated:
            print(
                f"stale: {args.output} differs from the generated output\n"
                "       re-run generate-swift-color-patches.py",
                file=sys.stderr,
            )
            return 1
        print(f"up to date: {os.path.relpath(args.output, REPO)}")
        return 0

    with open(args.output, "w") as handle:
        handle.write(generated)
    print(
        f"wrote {os.path.relpath(args.output, REPO)} "
        f"({len(PATCHES)} patches from {os.path.relpath(args.schema, REPO)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Select an available iPhone Simulator from `simctl list --json`.

The JSON can be piped on stdin or supplied with --input. The script is pure
apart from I/O so it can be exercised with fixture JSON on Linux.

Default primary policy
----------------------
Numbered modern iPhones (``iPhone 16``, ``iPhone 17 Pro``, ...) win over the
``iPhone SE`` line even when the SE is on a newer runtime: daily work should
stay on the modern primary device. Within the preferred pool the runtime is
ranked descending first, then the numeric model, then a stable natural-name
tie-break. The SE pool is only consulted when no numbered iPhone exists at all,
which keeps compact fallback possible without letting a newer SE outrank a
numbered device.

An explicit --udid (or IOS_SIMULATOR_ID via the wrapper) is validated against
the payload and fails closed: an unknown, unavailable, or wrong-family device
never falls back to another device or to --fallback-name. Non-iOS runtimes are
ignored, and --profile ipad requires an actual iPad, so the default phone pool
is never silently broadened.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable, NamedTuple

IPHONE_PREFIX = "iPhone"
IPAD_PREFIX = "iPad"
PROFILES = ("primary", "compact", "ipad")
SE_PATTERN = re.compile(r"(?<![A-Za-z])SE(?![A-Za-z])")
MODEL_NUMBER_PATTERN = re.compile(r"iPhone[ _-]*(\d+)", re.IGNORECASE)


class SelectionError(Exception):
    """Raised when an explicitly requested simulator cannot be used."""


class Device(NamedTuple):
    runtime: str
    name: str
    udid: str
    available: bool


def natural_key(value: str) -> tuple[tuple[int, object], ...]:
    """Case-insensitive, digit-aware sort key that never mixes int and str."""
    return tuple(
        (1, int(part)) if part.isdigit() else (0, part.casefold())
        for part in re.split(r"(\d+)", value)
        if part
    )


def runtime_key(runtime: str) -> tuple[int, ...]:
    version = re.search(r"iOS[- ](\d+(?:[-.]\d+)*)", runtime)
    if not version:
        return ()
    return tuple(int(part) for part in re.split(r"[-.]", version.group(1)))


def is_iphone(name: str) -> bool:
    return name.startswith(IPHONE_PREFIX)


def is_ipad(name: str) -> bool:
    return name.startswith(IPAD_PREFIX)


def is_ios_runtime(runtime: str) -> bool:
    """True only for iOS Simulator runtimes (not watchOS/tvOS/xrOS)."""
    return re.search(r"(?:^|[. ])iOS[- ]\d", runtime) is not None


def is_se(name: str) -> bool:
    return bool(SE_PATTERN.search(name))


def model_number(name: str) -> int:
    match = MODEL_NUMBER_PATTERN.search(name)
    return int(match.group(1)) if match else -1


def is_numbered_iphone(name: str) -> bool:
    return is_iphone(name) and not is_se(name) and model_number(name) >= 0


def iter_devices(payload: dict[str, Any]) -> Iterable[Device]:
    devices = payload.get("devices")
    if not isinstance(devices, dict):
        return
    for runtime, runtime_devices in devices.items():
        if not isinstance(runtime_devices, list):
            continue
        if not is_ios_runtime(str(runtime)):
            continue
        for device in runtime_devices:
            if not isinstance(device, dict):
                continue
            name = device.get("name")
            udid = device.get("udid")
            if not (isinstance(name, str) and isinstance(udid, str) and udid):
                continue
            yield Device(
                runtime=str(runtime),
                name=name,
                udid=udid,
                available=bool(device.get("isAvailable", False)),
            )


def available_iphones(payload: dict[str, Any]) -> list[Device]:
    return [device for device in iter_devices(payload) if device.available and is_iphone(device.name)]


def _selection_key(device: Device) -> tuple[object, ...]:
    return (
        runtime_key(device.runtime),
        model_number(device.name),
        natural_key(device.name),
        device.udid,
    )


def select_device(payload: dict[str, Any]) -> Device | None:
    """Pick the preferred daily iPhone, preferring numbered models over SE."""
    phones = available_iphones(payload)
    if not phones:
        return None
    numbered = [device for device in phones if is_numbered_iphone(device.name)]
    pool = numbered
    if not pool:
        pool = [device for device in phones if is_se(device.name)]
    if not pool:
        pool = phones
    pool.sort(key=_selection_key)
    return pool[-1]


def select_udid(payload: dict[str, Any]) -> str | None:
    device = select_device(payload)
    return device.udid if device else None


def find_device(payload: dict[str, Any], udid: str) -> Device | None:
    for device in iter_devices(payload):
        if device.udid == udid:
            return device
    return None


def validate_explicit(payload: dict[str, Any], udid: str, profile: str) -> str:
    """Return the requested UDID if it is an available device for the profile."""
    device = find_device(payload, udid)
    if device is None:
        raise SelectionError(f"requested simulator id is not present: {udid}")
    if not device.available:
        raise SelectionError(f"requested simulator is not available: {udid}")
    if profile == "ipad":
        if not is_ipad(device.name):
            raise SelectionError(f"requested simulator is not an iPad: {device.name}")
    elif not is_iphone(device.name):
        raise SelectionError(
            f"requested simulator is not an iPhone: {device.name} "
            "(use DEV_IOS_PROFILE=ipad for an explicit iPad)"
        )
    return udid


def load_payload(input_path: Path | None) -> dict[str, Any]:
    if input_path is not None:
        with input_path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        raise ValueError("simctl JSON root must be an object")
    return payload


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, help="Read simctl JSON from this file")
    parser.add_argument(
        "--format",
        choices=("udid", "destination"),
        default="udid",
        help="Print a raw UDID or an xcodebuild destination",
    )
    parser.add_argument(
        "--fallback-name",
        help="Use this Simulator name when no available iPhone is present",
    )
    parser.add_argument(
        "--udid",
        help="Require this explicit Simulator UDID; fails closed when absent",
    )
    parser.add_argument(
        "--profile",
        choices=PROFILES,
        default=None,
        help="Device profile; defaults to DEV_IOS_PROFILE or 'primary'",
    )
    return parser.parse_args(argv)


def resolve_profile(cli_value: str | None) -> str:
    profile = cli_value or os.environ.get("DEV_IOS_PROFILE") or "primary"
    return profile if profile in PROFILES else "primary"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    profile = resolve_profile(args.profile)
    try:
        payload = load_payload(args.input)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"select_simulator: invalid input: {error}", file=sys.stderr)
        return 2

    udid: str | None
    if args.udid is not None:
        requested = args.udid.strip()
        if not requested:
            print("select_simulator: --udid requires a non-empty value", file=sys.stderr)
            return 1
        try:
            udid = validate_explicit(payload, requested, profile)
        except SelectionError as error:
            print(f"select_simulator: {error}", file=sys.stderr)
            return 1
    else:
        udid = select_udid(payload)

    if args.format == "destination":
        if udid:
            print(f"platform=iOS Simulator,id={udid}")
            return 0
        if args.fallback_name:
            print(f"platform=iOS Simulator,name={args.fallback_name}")
            return 0
    elif udid:
        print(udid)
        return 0

    print("select_simulator: no available iPhone Simulator found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

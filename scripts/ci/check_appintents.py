#!/usr/bin/env python3
"""Verify the App Intents / SiriKit wiring of a built SideStore .app or .ipa.

Why this exists
---------------
SideStore ships two independent "Refresh All Apps" actions:

  1. the legacy SiriKit intent `RefreshAllIntent`
     (Intents.intentdefinition + INIntentsSupported + AppDelegate handler) - works on iOS 15+,
     this is what 0.5.8 used;
  2. the modern App Intent `RefreshAllAppsIntent`
     (Metadata.appintents/extract.actionsdata).

The App Intents metadata extractor stamps *every* App Intent with
`availabilityAnnotations.LNPlatformNameIOS.introducedVersion = 17.2`, so as soon as the App
Intent claims to migrate `RefreshAllIntent` (i.e. conforms to
`CustomIntentMigratedAppIntent` / sets `intentClassName`), iOS 17.0/17.1 resolve the action to
it, find it unavailable, and show "This action is not supported on iPhone" - while the working
SiriKit intent is shadowed.

This script asserts the two stay independent, and dumps the availability of every action so a
regression is visible in the build log.

Usage:  python3 scripts/ci/check_appintents.py path/to/SideStore.ipa
        python3 scripts/ci/check_appintents.py path/to/Payload/SideStore.app
"""

from __future__ import annotations

import json
import plistlib
import sys
import zipfile

LEGACY_INTENT = "RefreshAllIntent"
METADATA_SUFFIX = "Metadata.appintents/extract.actionsdata"


def _iter_members(root: str):
    """Yield (display_name, read_bytes_callable) for every bundle member."""
    if root.lower().endswith(".ipa"):
        with zipfile.ZipFile(root) as zf:
            for name in zf.namelist():
                if name.endswith(METADATA_SUFFIX):
                    yield name, zf.read(name)
                elif name.endswith("Info.plist") and name.count("/") <= 3:
                    yield name, zf.read(name)
    else:
        import os

        for dirpath, _dirnames, filenames in os.walk(root):
            for filename in filenames:
                full = os.path.join(dirpath, filename)
                rel = os.path.relpath(full, root).replace("\\", "/")
                if rel.endswith(METADATA_SUFFIX) or (
                    filename == "Info.plist" and rel.count("/") <= 1
                ):
                    with open(full, "rb") as handle:
                        yield rel, handle.read()


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    root = sys.argv[1]
    failures: list[str] = []

    try:
        members = list(_iter_members(root))
    except Exception as exc:  # noqa: BLE001
        print(f"error: cannot read {root}: {exc}")
        return 2

    if not members:
        print(f"error: no App Intents metadata / Info.plist found in {root}")
        return 2

    print(f"== {root}")
    for name, data in members:
        if name.endswith(METADATA_SUFFIX):
            print(f"\n-- {name}")
            try:
                payload = json.loads(data)
            except json.JSONDecodeError as exc:
                print(f"   !! unparseable JSON: {exc}")
                failures.append(f"{name}: unparseable")
                continue

            generator = payload.get("generator", {})
            print(f"   generator: {generator.get('name')} {generator.get('version')}")

            for action_name, action in sorted(payload.get("actions", {}).items()):
                availability = action.get("availabilityAnnotations", {})
                ios = availability.get("LNPlatformNameIOS", {}).get(
                    "introducedVersion", "?"
                )
                migrated = action.get("customIntentClassName")
                print(
                    f"   {action_name:<32} iOS>={ios:<5}"
                    f" customIntentClassName={migrated or '-'}"
                )
                if migrated == LEGACY_INTENT:
                    failures.append(
                        f"{action_name} still claims customIntentClassName="
                        f"'{LEGACY_INTENT}': it shadows the SiriKit intent and makes "
                        f"'Refresh All Apps' unsupported on iOS 17.0/17.1"
                    )
            continue

        # Info.plist
        try:
            info = plistlib.loads(data)
        except Exception:  # noqa: BLE001
            continue
        if "INIntentsSupported" not in info:
            continue
        supported = info["INIntentsSupported"]
        print(f"\n-- {name}\n   INIntentsSupported: {supported}")
        if LEGACY_INTENT not in supported:
            failures.append(
                f"{name}: INIntentsSupported is missing '{LEGACY_INTENT}', so the "
                f"iOS 17.0/17.1 fallback path is gone"
            )

    print()
    if failures:
        print("FAILED:")
        for failure in failures:
            print(f" - {failure}")
        return 1

    print("OK: App Intents and the legacy SiriKit intent are independent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

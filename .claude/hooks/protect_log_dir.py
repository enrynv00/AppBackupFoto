#!/usr/bin/env python3
"""PreToolUse hook: blocca Write/Edit sotto AppBackupFoto/Log/ (foto reali, mai foto di test)."""
import json
import sys


def main():
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = event.get("tool_name", "")
    if tool_name not in ("Write", "Edit"):
        sys.exit(0)

    file_path = event.get("tool_input", {}).get("file_path", "")
    if "/Log/" in file_path or file_path.endswith("/Log"):
        print(
            "BLOCCATO: scrittura sotto AppBackupFoto/Log/ - quella cartella contiene foto reali "
            "dell'utente, mai foto di test. Se serve davvero scrivere qui, chiedi conferma esplicita "
            "all'utente prima di procedere.",
            file=sys.stderr,
        )
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()

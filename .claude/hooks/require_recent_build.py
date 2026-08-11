#!/usr/bin/env python3
"""Stop hook: se questa sessione ha modificato ContentView.swift o i test, richiede
che compaia un BUILD SUCCEEDED / TEST SUCCEEDED successivo nella trascrizione
prima di lasciar terminare la sessione."""
import json
import sys

EDIT_TOOLS = ("Edit", "Write")
SOURCE_MARKERS = ("ContentView.swift", "AppBackupFotoTests")
SUCCESS_MARKERS = ("BUILD SUCCEEDED", "TEST SUCCEEDED")


def main():
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    transcript_path = event.get("transcript_path")
    if not transcript_path:
        sys.exit(0)

    last_edit_idx = None
    last_success_idx = None
    try:
        with open(transcript_path) as f:
            for idx, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                text = json.dumps(entry)
                if any(tool in text for tool in EDIT_TOOLS) and any(m in text for m in SOURCE_MARKERS):
                    last_edit_idx = idx
                if any(m in text for m in SUCCESS_MARKERS):
                    last_success_idx = idx
    except OSError:
        sys.exit(0)

    if last_edit_idx is None:
        sys.exit(0)

    if last_success_idx is None or last_success_idx < last_edit_idx:
        print(
            "BLOCCATO: hai modificato ContentView.swift o i test di AppBackupFoto in questa "
            "sessione ma non risulta un BUILD SUCCEEDED/TEST SUCCEEDED successivo nella "
            "trascrizione. Esegui 'xcodebuild ... build' (e i test se rilevanti) prima di terminare.",
            file=sys.stderr,
        )
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()

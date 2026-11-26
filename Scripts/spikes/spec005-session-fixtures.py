"""Capture bounded, anonymized metadata trees. Never open agent log contents."""
import datetime
import itertools
import json
import os
from pathlib import Path
import re
import stat
import sys


def capture(home, root, agent):
    base = home / root
    aliases = {}
    entries = []
    truncated = False

    def component(name, directory):
        if name in {"chats", "logs", "subagents", "tool-results", ".project_root", "logs.json"}:
            return name
        if directory and re.fullmatch(r"\d{2}|\d{4}", name):
            return name
        key = (name, directory)
        if key not in aliases:
            if directory:
                aliases[key] = f"project-{len(aliases) + 1:04d}"
            else:
                suffix = "".join(Path(name).suffixes)
                prefix = "rollout-" if name.startswith("rollout-") else "session-" if name.startswith("session-") else "file-"
                aliases[key] = f"{prefix}{len(aliases) + 1:04d}{suffix}"
        return aliases[key]

    def walk(path, relative, depth):
        nonlocal truncated
        try:
            with os.scandir(path) as scan:
                children = list(itertools.islice(scan, 513))
            if len(children) > 512:
                truncated = True
            for child in sorted(children[:512], key=lambda item: item.name):
                if len(entries) >= 512:
                    truncated = True
                    return
                metadata = child.stat(follow_symlinks=False)
                directory = stat.S_ISDIR(metadata.st_mode)
                safe = relative + [component(child.name, directory)]
                kind = "directory" if directory else "file" if stat.S_ISREG(metadata.st_mode) else "symlink" if stat.S_ISLNK(metadata.st_mode) else "other"
                entry = {"path": "/".join(safe), "kind": kind}
                if kind == "file":
                    entry.update(size=metadata.st_size, modifiedAt=datetime.datetime.fromtimestamp(metadata.st_mtime, datetime.timezone.utc).isoformat())
                entries.append(entry)
                if directory:
                    if depth < 4:
                        walk(Path(child.path), safe, depth + 1)
                    else:
                        truncated = True
        except OSError:
            entries.append({"path": "/".join(relative), "kind": "unreadable"})

    exists = base.is_dir()
    if exists:
        walk(base, [], 0)
    result = {"agent": agent, "root": "~/" + root, "available": exists,
              "truncated": truncated, "entries": entries}
    if agent == "claude":
        # Verify an actual known cwd without persisting its name or its encoded path.
        result["cwdSeparatorReplacementObserved"] = (base / str(Path.cwd()).replace("/", "-")).is_dir()
        result["encodingExample"] = {"cwd": "/fixture/workspace/project", "directory": "-fixture-workspace-project"}
    return result


if __name__ == "__main__":
    destination = Path(sys.argv[1])
    destination.mkdir(parents=True, exist_ok=True)
    for agent, root in [("claude", ".claude/projects"), ("codex", ".codex/sessions"), ("gemini", ".gemini/tmp")]:
        result = capture(Path.home(), root, agent)
        result.update(schemaVersion=1, capturedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      sanitization="Project and session names replaced; dates, suffixes, sizes and mtimes retained; no file contents or symlink targets read")
        (destination / f"{agent}.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")

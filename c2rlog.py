#!/usr/bin/env python3
r"""Follow Click-to-Run's logs during an Office install (used by install.sh).

Click-to-Run writes <COMPUTERNAME>-<date>-<time>.log files, UTF-16 with a BOM, into the user's and
SYSTEM's %TEMP%. This reads the log files modified after STAMP incrementally (offsets are kept in
STATE, a JSON file), so a log that grows by hundreds of MB in a retry loop is read only once.

  c2rlog.py scan STATE STAMP DIR...   print "<progress> <complete> <failed> <neterrors> <tasks>":
                                      highest "total progress is now N", 1 if the installation
                                      reported completion, 1 if a task failed, the number of
                                      connection errors, the failed tasks (comma-separated, or -)
  c2rlog.py errors STATE              print the last log lines about failures
"""
import json
import os
import re
import sys

PROGRESS = re.compile(r"total progress is now (\d+)")
TASK = re.compile(r'"Executing Task\\?":\\?"([A-Z_]+)')
FAILED = ("Encountered fatal exception", "TASKSTATE_FAILED")
COMPLETE = "Installation progress completed."
NETERROR = re.compile(r"ServerReachabilityError|0x80072ef[1-9a-d]|0x80072ee[2-7]")


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"files": {}, "progress": 0, "complete": False, "failed": False, "neterrors": 0,
                "tasks": [], "lines": []}


def scan_file(st, path, info):
    try:
        size = os.path.getsize(path)
        if size < info["offset"]:  # replaced
            info.update(offset=0, enc=None)
        if size == info["offset"]:
            return
        with open(path, "rb") as f:
            f.seek(info["offset"])
            data = f.read()
    except OSError:
        return
    if info["enc"] is None:
        if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
            info["enc"] = "utf-16-le" if data[:2] == b"\xff\xfe" else "utf-16-be"
            data, info["offset"] = data[2:], info["offset"] + 2
        else:
            info["enc"] = "utf-8"
    # only complete lines; the rest is read again next time
    if info["enc"].startswith("utf-16"):
        nl = b"\n\x00" if info["enc"] == "utf-16-le" else b"\x00\n"
        i = data.rfind(nl)
        while i >= 0 and i % 2:
            i = data.rfind(nl, 0, i)
        end = i + 2 if i >= 0 else 0
    else:
        end = data.rfind(b"\n") + 1
    if end <= 0:
        return
    text = data[:end].decode(info["enc"], errors="replace")
    info["offset"] += end
    for line in text.splitlines():
        m = PROGRESS.search(line)
        if m:
            st["progress"] = max(st["progress"], int(m.group(1)))
            continue
        if COMPLETE in line:
            st["complete"] = True
        if NETERROR.search(line):
            st["neterrors"] += 1
        if any(s in line for s in FAILED):
            st["failed"] = True
            st["lines"] = (st["lines"] + [line.strip()[:2000]])[-20:]
            for t in TASK.findall(line):
                if t not in st["tasks"]:
                    st["tasks"].append(t)


def scan(state_path, stamp, dirs):
    st = load(state_path)
    since = os.path.getmtime(stamp)
    for d in dirs:
        base = d.rstrip("/").count("/")
        for root, subdirs, files in os.walk(d):
            if root.count("/") - base >= 4:
                subdirs[:] = []
            for name in files:
                if not name.lower().endswith(".log"):
                    continue
                p = os.path.join(root, name)
                try:
                    if os.path.getmtime(p) < since:
                        continue
                except OSError:
                    continue
                scan_file(st, p, st["files"].setdefault(p, {"offset": 0, "enc": None}))
    tmp = state_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, state_path)
    print(st["progress"], int(st["complete"]), int(st["failed"]), st["neterrors"],
          ",".join(st["tasks"]) or "-")


def main(argv):
    if len(argv) >= 4 and argv[1] == "scan":
        scan(argv[2], argv[3], argv[4:])
    elif len(argv) == 3 and argv[1] == "errors":
        for line in load(argv[2])["lines"]:
            print(line)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)

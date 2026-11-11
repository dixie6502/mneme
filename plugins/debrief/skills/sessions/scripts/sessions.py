#!/usr/bin/env python3
"""Print this machine's live Claude sessions, then the other tmux panes.

Usage: sessions.py [--count]
  --count  one line for debrief: how many other live sessions, by status

Sessions come from `claude agents --json` (interactive and background), else from
Claude Code's per-process files in ~/.claude/sessions/. Each is matched to its tmux
pane through the process tree, and to its transcript for the title (the user's
/rename, else Claude's) and the latest recap ("while you were away"). A pane's
screen is never read: it may hold secrets.
"""

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

HOME = Path.home()
CLAUDE_PROJECTS = HOME / ".claude/projects"
CLAUDE_SESSION_FILES = HOME / ".claude/sessions"
RECAP_SUFFIX = " (disable recaps in /config)"
SECONDS_PER_MINUTE = 60


@dataclass
class Session:
    """One live Claude session, as Claude Code reports it."""

    pid: int
    cwd: str
    kind: str
    status: str
    name: str
    session_id: str
    started_at: datetime | None


@dataclass
class Pane:
    """One tmux pane: its id (session:window.pane), foreground command and folder."""

    pane_id: str
    command: str
    path: str


def run(command: list[str]) -> str:
    """Run a command and return its stdout, or "" if it fails or is missing."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError:
        return ""
    return result.stdout if result.returncode == 0 else ""


def from_milliseconds(value: object) -> datetime | None:
    """A Unix time in milliseconds as a datetime, or None."""
    return datetime.fromtimestamp(value / 1000, UTC) if isinstance(value, int) else None


def session_from(record: dict) -> Session:
    """A Session from one `claude agents --json` entry or ~/.claude/sessions file."""
    return Session(
        pid=int(record.get("pid", 0)),
        cwd=record.get("cwd", ""),
        kind=record.get("kind", ""),
        status=record.get("status", "unknown"),
        name=record.get("name", ""),
        session_id=record.get("sessionId", ""),
        started_at=from_milliseconds(record.get("startedAt")),
    )


def is_running(pid: int) -> bool:
    """Whether a process with this id exists."""
    return Path(f"/proc/{pid}").exists()


def list_sessions() -> list[Session]:
    """Live sessions from `claude agents --json`, else from Claude Code's session files."""
    output = run(["claude", "agents", "--json"])
    try:
        return [session_from(record) for record in json.loads(output)]
    except ValueError:
        pass
    sessions = []
    for session_file in sorted(CLAUDE_SESSION_FILES.glob("*.json")):
        try:
            session = session_from(json.loads(session_file.read_text()))
        except (OSError, ValueError):
            continue
        if session.pid and is_running(session.pid):
            sessions.append(session)
    return sessions


def list_panes() -> dict[int, Pane]:
    """tmux panes by the id of the process they run; empty without tmux."""
    panes = {}
    pane_format = (
        "#{pane_pid}\t#{session_name}:#{window_index}.#{pane_index}"
        "\t#{pane_current_command}\t#{pane_current_path}"
    )
    for line in run(["tmux", "list-panes", "-a", "-F", pane_format]).splitlines():
        pane_pid, pane_id, command, path = line.split("\t", 3)
        panes[int(pane_pid)] = Pane(pane_id, command, path)
    return panes


def parent_of(pid: int) -> int:
    """Parent process id, from /proc (1 when unknown)."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return 1
    # The command name is in parentheses and may hold spaces: fields follow the last ')'.
    return int(stat.rsplit(")", 1)[1].split()[1])


def ancestors(pid: int) -> list[int]:
    """The process and its parents, up to init."""
    chain = []
    while pid > 1:
        chain.append(pid)
        pid = parent_of(pid)
    return chain


def read_title_and_recap(session_id: str) -> tuple[str, str, datetime | None, float]:
    """Title, latest recap, its time, and the transcript's last write (Unix time)."""
    transcripts = (
        list(CLAUDE_PROJECTS.glob(f"*/{session_id}.jsonl")) if session_id else []
    )
    if not transcripts:
        return "", "", None, 0.0
    ai_title = custom_title = recap = ""
    recap_time = None
    with transcripts[0].open(errors="replace") as lines:
        for line in lines:
            if not any(key in line for key in ("-title", "away_summary")):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") == "ai-title":
                ai_title = entry.get("aiTitle", ai_title)
            elif entry.get("type") == "custom-title":
                custom_title = entry.get("customTitle", custom_title)
            elif entry.get("subtype") == "away_summary":
                recap = str(entry.get("content", "")).removesuffix(RECAP_SUFFIX)
                recap_time = datetime.fromisoformat(entry["timestamp"])
    return custom_title or ai_title, recap, recap_time, transcripts[0].stat().st_mtime


def format_age(seconds: float) -> str:
    """A duration as '5 min', '3 h' or '2 d'."""
    minutes = int(seconds // SECONDS_PER_MINUTE)
    if minutes < 60:
        return f"{minutes} min"
    if minutes < 24 * 60:
        return f"{minutes // 60} h"
    return f"{minutes // (24 * 60)} d"


def display_path(path: str) -> str:
    """A folder relative to home, GitHub clones without the host."""
    if path == str(HOME):
        return "~"
    return path.removeprefix(f"{HOME}/").removeprefix("GitHub/")


def render_session(session: Session, pane: Pane | None, is_own: bool) -> list[str]:
    """One line per session, plus its recap when there is one."""
    now = datetime.now(UTC)
    title, recap, recap_time, last_write = read_title_and_recap(session.session_id)
    parts = [f"`{display_path(session.cwd)}`"]
    if session.name:
        parts.append(session.name + (" (this session)" if is_own else ""))
    if session.kind and session.kind != "interactive":
        parts.append(session.kind)
    parts.append(session.status)
    parts.append(f"tmux {pane.pane_id}" if pane else "no tmux")
    if session.started_at:
        parts.append(f"up {format_age((now - session.started_at).total_seconds())}")
    if last_write:
        parts.append(f"active {format_age(now.timestamp() - last_write)} ago")
    if title:
        parts.append(title)
    lines = ["- " + " · ".join(parts)]
    if recap and recap_time:
        age = format_age((now - recap_time).total_seconds())
        lines.append(f"  Recap, {age} ago: {recap}")
    return lines


def main() -> None:
    """Print the sessions and panes, or the one-line count for debrief."""
    sessions = list_sessions()
    panes = list_panes()
    own_chain = ancestors(os.getpid())
    pane_of_session: dict[int, Pane | None] = {}
    for session in sessions:
        chain = ancestors(session.pid)
        pane_of_session[session.pid] = next(
            (panes[pid] for pid in chain if pid in panes), None
        )
    own_pid = next((s.pid for s in sessions if s.pid in own_chain), 0)

    if "--count" in sys.argv[1:]:
        others = [session for session in sessions if session.pid != own_pid]
        if others:
            statuses: dict[str, int] = {}
            for session in others:
                statuses[session.status] = statuses.get(session.status, 0) + 1
            summary = ", ".join(
                f"{status} {count}" for status, count in statuses.items()
            )
            print(
                f"- {len(others)} other live Claude session(s) ({summary}): /sessions"
            )
        return

    claude_panes = {id(pane) for pane in pane_of_session.values() if pane}
    print("**Claude sessions**\n")
    for session in sessions:
        lines = render_session(
            session, pane_of_session[session.pid], session.pid == own_pid
        )
        print("\n".join(lines))
    if not sessions:
        print("- None running.")
    other_panes = [pane for pane in panes.values() if id(pane) not in claude_panes]
    if other_panes:
        print("\n**Other tmux panes**\n")
        for pane in sorted(other_panes, key=lambda pane: pane.pane_id):
            print(f"- {pane.pane_id} · {pane.command} · `{display_path(pane.path)}`")


if __name__ == "__main__":
    main()

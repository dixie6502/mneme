#!/usr/bin/env python3
"""Print the /debrief report: what needs the user, what runs now, the log, projects.

Usage: report.py [all] [last|N] [filter]
  all     every project, even when run inside one
  last    log entries since the previous `all` debrief
  N       the latest N log entries (default 3)
  filter  substring of a project scope (e.g. dixie6502/construct): that project in full

Run inside a clone or scratch topic without `all` or a filter, it is local: the
filter is the current scope (as memo defines it), and "Needs you" adds the global
scope's questions and actions.

The report is markdown with a fixed layout; a section shows only when its data
exists, so it works with any mix of the memo and memex plugins. Their files
are read directly, as interfaces owned by those plugins (ARCHITECTURE.md > debrief).
After the report, a context block gives the model the log details for its one
summary line. Only side effect: an unfiltered run records its time for the next
`last`.
"""

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

HOME = Path.home()
SKILLS_DIR = Path(__file__).resolve().parents[2]
SESSIONS_SCRIPT = SKILLS_DIR / "sessions/scripts/sessions.py"  # same plugin
LAST_DEBRIEF_FILE = HOME / ".cache/debrief/last-run"
# Data of the memex plugin, read when present: the log, knowledge, backup state.
LOG_ENTRIES = HOME / "log/entries.jsonl"
KNOWLEDGE_DIR = HOME / "knowledge"
DREAM_PROPOSALS = KNOWLEDGE_DIR / ".dream/proposals.json"
RUN_LOG = HOME / ".cache/memex/log/run.log"
LAST_BACKUP_FILE = HOME / ".cache/memex/log/last-backup"
BACKUP_MAX_AGE_DAYS = 2  # the sweep backs up daily; one missed day is not news
# Data of the memo plugin: ~/memo/<scope>/TODO.md and note/*.md (a `created:`
# frontmatter date, else the file's mtime, stale after 28 days), the sync log.
MEMO_DIR = HOME / "memo"
MEMO_SYNC_LOG = HOME / ".cache/memo/sync.log"
GLOBAL_SCOPE = "global"
STALE_NOTE_DAYS = 28
OWN_OWNER = "dixie6502"
DEFAULT_ENTRIES_SHOWN = 3
TODO_SECTIONS = ("You", "Now", "Next", "Later")
CONTEXT_MARKER = "----- context for the summary line, do not print -----"
CLAUDE_PROJECTS = HOME / ".claude/projects"
SECONDS_PER_DAY = 86400


@dataclass
class TodoItem:
    """One TODO.md item: its text with detail lines joined, and whether it is ticked."""

    text: str
    is_ticked: bool


@dataclass
class Project:
    """Everything known about one project, keyed by its memo scope (owner/repo, ...)."""

    name: str
    todo: dict[str, list[TodoItem]] = field(default_factory=dict)
    issues: list[dict] = field(default_factory=list)
    is_issues_unreadable: bool = False


def clone_paths(pattern: str) -> list[Path]:
    """Matches of a glob under $HOME, skipping hidden folders (.cache, .local, ...)."""
    return sorted(
        path
        for path in HOME.glob(pattern)
        if not path.relative_to(HOME).parts[0].startswith(".")
    )


def scope_of(directory: Path) -> str:
    """memo's scope of a directory: owner/repo in a clone, scratch/<topic>, else global."""
    home = HOME.resolve()
    common = run(
        [
            "git",
            "-C",
            str(directory),
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ]
    ).strip()
    if common:
        clone = Path(common).parent
        if clone.is_relative_to(home):
            parts = clone.relative_to(home).parts
            if len(parts) == 3 and parts[0] != "scratch":
                return f"{parts[1]}/{parts[2]}"
    directory = directory.resolve()
    if directory.is_relative_to(home / "scratch"):
        parts = directory.relative_to(home / "scratch").parts
        if parts:
            return f"scratch/{parts[0]}"
    return GLOBAL_SCOPE


def memo_scopes(pattern: str) -> list[tuple[str, Path]]:
    """(scope, path) for each match of a glob in the memo store, e.g. `*/*/TODO.md`."""
    matches = [*MEMO_DIR.glob(pattern), *MEMO_DIR.glob(f"{GLOBAL_SCOPE}/{pattern[4:]}")]
    return sorted(
        (str(path.relative_to(MEMO_DIR).parent), path)
        for path in matches
        if not path.relative_to(MEMO_DIR).parts[0].startswith(".")
    )


def run(command: list[str]) -> str:
    """Run a command and return its stdout, or "" if it fails."""
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    return result.stdout if result.returncode == 0 else ""


def parse_arguments(arguments: list[str]) -> tuple[bool, str, str]:
    """Split the arguments into `all`, the log selection (last or N) and the filter."""
    is_all = bool(arguments) and arguments[0] == "all"
    if is_all:
        arguments = arguments[1:]
    selection = str(DEFAULT_ENTRIES_SHOWN)
    if arguments and (
        arguments[0] == "last" or re.fullmatch(r"[1-9]\d*", arguments[0])
    ):
        selection = arguments.pop(0)
    return is_all, selection, " ".join(arguments)


def read_todo(todo_file: Path) -> dict[str, list[TodoItem]]:
    """Parse a TODO.md into its sections; detail lines are joined to their item."""
    sections: dict[str, list[TodoItem]] = {}
    current: list[TodoItem] | None = None
    for line in todo_file.read_text().splitlines():
        if line.startswith("## "):
            current = sections.setdefault(line[3:].strip(), [])
        elif current is not None and re.match(r"- \[[ x]\] ", line):
            current.append(TodoItem(line[6:].strip(), line.startswith("- [x]")))
        elif current and line.startswith("  ") and line.strip():
            current[-1].text += " " + line.strip()
    return sections


def read_issues(repo: str) -> tuple[list[dict], bool]:
    """Open issues of one GitHub repo; the flag is True when they cannot be read."""
    output = run(
        [
            "gh",
            "issue",
            "list",
            "-R",
            repo,
            "--state",
            "open",
            "--limit",
            "200",
            "--json",
            "number,title,labels,assignees",
        ]
    )
    if not output:
        has_issues = run(["gh", "api", f"repos/{repo}", "--jq", ".has_issues"]).strip()
        return [], has_issues != "false" and has_issues != ""
    return json.loads(output), False


def collect_projects(project_filter: str) -> list[Project]:
    """Projects with a TODO.md in the memo store or a GitHub clone, matching the filter."""
    projects: dict[str, Project] = {}

    def project_at(scope: str) -> Project:
        return projects.setdefault(scope, Project(scope))

    for scope, todo_file in memo_scopes("*/*/TODO.md"):
        if project_filter in scope:
            project_at(scope).todo = read_todo(todo_file)
    clones = [
        str(git.parent.relative_to(HOME / "GitHub"))
        for git in clone_paths("GitHub/*/*/.git")
    ]
    clones = [scope for scope in clones if project_filter in scope]
    with ThreadPoolExecutor() as pool:
        results = pool.map(read_issues, clones)
        for scope, (issues, is_unreadable) in zip(clones, results, strict=True):
            if issues or is_unreadable:
                project_at(scope).issues = issues
                project_at(scope).is_issues_unreadable = is_unreadable
    return sorted(projects.values(), key=lambda project: project.name)


def read_global_project() -> list[Project]:
    """The global scope's TODO.md, for "Needs you" in a local debrief."""
    todo_file = MEMO_DIR / GLOBAL_SCOPE / "TODO.md"
    if not todo_file.exists():
        return []
    return [Project(GLOBAL_SCOPE, todo=read_todo(todo_file))]


def is_waiting_on_user(issue: dict) -> bool:
    """An issue labelled `user` waits on the user."""
    return any(label["name"] == "user" for label in issue["labels"])


def read_log_entries(selection: str, project_filter: str) -> tuple[list[dict], str]:
    """The log entries to show, and the section title describing them."""
    entries = []
    if LOG_ENTRIES.exists():
        entries = [
            json.loads(line) for line in LOG_ENTRIES.read_text().splitlines() if line
        ]
    if project_filter:
        entries = [
            entry
            for entry in entries
            if any(project_filter in repo for repo in entry_repos(entry))
        ]
    entries.sort(key=lambda entry: entry["end"])
    if selection == "last":
        since = (
            LAST_DEBRIEF_FILE.read_text().strip() if LAST_DEBRIEF_FILE.exists() else ""
        )
        if since:
            shown = [entry for entry in entries if entry["end"] > since]
            return shown, f"since the last debrief, {format_time(since)}"
        selection = str(DEFAULT_ENTRIES_SHOWN)
        return entries[
            -int(selection) :
        ], f"latest {selection}, no previous debrief recorded"
    return entries[-int(selection) :], f"latest {selection}"


def entry_repos(entry: dict) -> list[str]:
    """Projects an entry touched; entries before the repos field use their directory."""
    return entry.get("repos") or [entry["cwd"].removeprefix(f"{HOME}/")]


def format_time(timestamp: str) -> str:
    """ISO UTC timestamp as 'MM-DD HH:MM UTC'."""
    return f"{timestamp[5:10]} {timestamp[11:16]} UTC"


def collect_local_state(project_filter: str) -> list[str]:
    """One line per clone with uncommitted or unpushed work."""
    lines = []
    for git in clone_paths("*/*/*/.git"):
        path = str(git.parent.relative_to(HOME))
        if project_filter not in path:
            continue
        changed = len(
            run(["git", "-C", str(git.parent), "status", "--porcelain"]).splitlines()
        )
        unpushed = run(
            ["git", "-C", str(git.parent), "rev-list", "--count", "@{upstream}..HEAD"]
        )
        unpushed_text = f"{unpushed.strip()} unpushed" if unpushed else "no upstream"
        if changed or unpushed_text != "0 unpushed":
            lines.append(
                f"- `{path.removeprefix('GitHub/')}`: {changed} uncommitted, {unpushed_text}"
            )
    return lines


def collect_live_sessions() -> list[str]:
    """One line counting the other live Claude sessions; details are in /sessions."""
    return run([str(SESSIONS_SCRIPT), "--count"]).splitlines()


def render_needs_you(projects: list[Project]) -> list[str]:
    """Questions first, then actions, then issues labelled `user`."""
    items = [
        (project, item) for project in projects for item in project.todo.get("You", [])
    ]
    items.sort(key=lambda pair: not pair[1].text.startswith("?"))
    lines = [
        f"- `{project.name}` {item.text}{' (ticked: act on it)' if item.is_ticked else ''}"
        for project, item in items
    ]
    lines += [
        f"- `{project.name}#{issue['number']}` {issue['title']}"
        for project in projects
        for issue in project.issues
        if is_waiting_on_user(issue)
    ]
    return lines


def claude_project_slug(directory: Path) -> str:
    """Claude Code's folder name for a session start directory: non-alphanumerics → '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(directory))


def render_memory_line(project_filter: str) -> list[str]:
    """One line listing projects whose memory holds notes, as a reminder to promote them."""
    known = [
        HOME,
        HOME / "scratch",
        *(path.parent for path in clone_paths("*/*/*/.git")),
    ]
    known += clone_paths("scratch/*/")
    path_by_slug = {claude_project_slug(path): path for path in known}
    parts = []
    for memory in sorted(CLAUDE_PROJECTS.glob("*/memory")):
        notes = [note for note in memory.glob("*.md") if note.name != "MEMORY.md"]
        if not notes:
            continue
        directory = path_by_slug.get(memory.parent.name)
        name = str(directory.relative_to(HOME)) if directory else memory.parent.name
        name = name.removeprefix("GitHub/") if name != "." else "~"
        if project_filter not in name:
            continue
        oldest_days = int(
            (datetime.now().timestamp() - min(note.stat().st_mtime for note in notes))
            / SECONDS_PER_DAY
        )
        parts.append(
            f"`{name}` {len(notes)} note{'s' if len(notes) > 1 else ''} "
            f"(oldest {oldest_days} d)"
        )
    if not parts:
        return []
    return ["- Memory to promote: " + " · ".join(parts)]


def note_age_days(note: Path) -> int:
    """Days since a note was created: its frontmatter `created:` date, else its mtime."""
    lines = note.read_text(errors="replace").splitlines()
    created = None
    if lines and lines[0] == "---":
        for line in lines[1:]:
            if line == "---":
                break
            if line.startswith("created: "):
                try:
                    created = datetime.strptime(line.split()[1], "%Y-%m-%d")
                except (IndexError, ValueError):
                    pass
                break
    created = created or datetime.fromtimestamp(note.stat().st_mtime)
    return int((datetime.now() - created).total_seconds() // SECONDS_PER_DAY)


def render_stale_notes_line(project_filter: str) -> list[str]:
    """One line listing scopes with stale notes, to convert into docs or delete."""
    parts = []
    for name, note_dir in memo_scopes("*/*/note"):
        if project_filter not in name:
            continue
        ages = [note_age_days(note) for note in note_dir.glob("*.md")]
        stale = [age for age in ages if age > STALE_NOTE_DAYS]
        if stale:
            parts.append(f"`{name}` {len(stale)} (oldest {max(stale)} d)")
    if not parts:
        return []
    return ["- Notes to convert or delete: " + " · ".join(parts)]


def render_knowledge_changes() -> list[str]:
    """Knowledge entries changed since the last unfiltered debrief (all, if none yet)."""
    if not (KNOWLEDGE_DIR / ".git").exists():
        return []
    since = LAST_DEBRIEF_FILE.read_text().strip() if LAST_DEBRIEF_FILE.exists() else ""
    command = ["git", "-C", str(KNOWLEDGE_DIR), "log", "--name-only", "--format="]
    if since:
        command.append(f"--since={since}")
    changed = sorted(
        {
            path.removesuffix(".md")
            for path in run(command).splitlines()
            if path.endswith(".md") and "/" in path
        }
    )
    entries = [path for path in changed if path.split("/")[0] != path.split("/")[1]]
    return [f"- `{entry}`" for entry in entries]


def render_dream_line() -> list[str]:
    """One line when knowledge dream proposals wait for the user: to review, or failed."""
    if not DREAM_PROPOSALS.exists():
        return []
    proposals = json.loads(DREAM_PROPOSALS.read_text()).get("proposals", [])
    to_review: dict[str, int] = {}
    for proposal in proposals:
        if proposal.get("status") == "open":
            to_review[proposal["layer"]] = to_review.get(proposal["layer"], 0) + 1
    failed = sum(1 for proposal in proposals if proposal.get("status") == "failed")
    parts = []
    if to_review:
        layers = ", ".join(
            f"{layer} {count}" for layer, count in sorted(to_review.items())
        )
        parts.append(f"{sum(to_review.values())} to review ({layers})")
    if failed:
        parts.append(f"{failed} failed to apply")
    if not parts:
        return []
    return [f"- Knowledge dream: {' · '.join(parts)}: `/knowledge dream [owner]`"]


def render_knowledge_failures() -> list[str]:
    """One line when knowledge has stashed work: failed checks or interrupted runs."""
    if not (KNOWLEDGE_DIR / ".git").exists():
        return []
    count = len(run(["git", "-C", str(KNOWLEDGE_DIR), "stash", "list"]).splitlines())
    if not count:
        return []
    stash = "`git -C ~/knowledge stash list`"
    return [f"- Knowledge: {count} failed or interrupted write(s) kept in {stash}"]


def render_memo_sync_line() -> list[str]:
    """One line when the memo store is not synced: no remote, unpushed, or failing."""
    if not (MEMO_DIR / ".git").exists():
        return []
    if not run(["git", "-C", str(MEMO_DIR), "remote"]).strip():
        return ["- Memo: no remote, the store exists only on this host"]
    parts = []
    unpushed = run(
        ["git", "-C", str(MEMO_DIR), "rev-list", "--count", "@{upstream}..HEAD"]
    ).strip()
    if unpushed != "0":
        parts.append(f"{unpushed} unpushed commit(s)" if unpushed else "never pushed")
    last_line = (
        MEMO_SYNC_LOG.read_text().splitlines()[-1:] if MEMO_SYNC_LOG.exists() else []
    )
    if last_line and " error: " in last_line[0]:
        parts.append("last sync failed: " + last_line[0].split(" error: ", 1)[1])
    if not parts:
        return []
    return ["- Memo sync: " + " · ".join(parts)]


def render_backup_line() -> list[str]:
    """One line when the log runs here and its backup is unconfigured or too old."""
    if not LOG_ENTRIES.exists():
        return []
    if not os.environ.get("MEMEX_BACKUP_DIR"):
        return ["- Backup: not configured, transcripts exist only on this host"]
    see_log = f"see `~/{RUN_LOG.relative_to(HOME)}`"
    if not LAST_BACKUP_FILE.exists():
        return [f"- Backup: no success yet, {see_log}"]
    age_days = int(
        (datetime.now().timestamp() - LAST_BACKUP_FILE.stat().st_mtime)
        / SECONDS_PER_DAY
    )
    if age_days < BACKUP_MAX_AGE_DAYS:
        return []
    return [f"- Backup: last success {age_days} d ago, {see_log}"]


def render_project_line(project: Project) -> str:
    """Big-picture line: what's next, then counts."""
    now, upcoming = project.todo.get("Now", []), project.todo.get("Next", [])
    parts = []
    if now:
        parts.append(f"now: {now[0].text}")
    elif upcoming:
        parts.append(f"next: {upcoming[0].text}")
    elif project.todo:
        parts.append("idle")
    remaining_next = len(upcoming) - (0 if now else min(len(upcoming), 1))
    if remaining_next:
        parts.append(f"+{remaining_next} next")
    if project.todo.get("Later"):
        parts.append(f"{len(project.todo['Later'])} later")
    if project.issues:
        assigned = sum(
            any(user["login"] == OWN_OWNER for user in issue["assignees"])
            for issue in project.issues
        )
        parts.append(
            f"{len(project.issues)} open issues"
            + (f" ({assigned} assigned to {OWN_OWNER})" if assigned else "")
        )
    if project.is_issues_unreadable:
        parts.append("issues not readable")
    return f"- `{project.name}`: " + " · ".join(parts)


def render_project_in_full(project: Project) -> list[str]:
    """Filtered view: the TODO file (You is under Needs you) and every open issue."""
    lines = [f"**{project.name}**", ""]
    for section in TODO_SECTIONS[1:]:
        for item in project.todo.get(section, []):
            lines.append(
                f"- {section}: {item.text}{' (ticked)' if item.is_ticked else ''}"
            )
    for issue in project.issues:
        labels = ",".join(label["name"] for label in issue["labels"])
        lines.append(
            f"- Issue #{issue['number']}: {issue['title']}"
            + (f" [{labels}]" if labels else "")
        )
    if project.is_issues_unreadable:
        lines.append("- Issues not readable")
    if len(lines) == 2:
        lines.append("- Nothing open")
    return lines + [""]


def render_entry(entry: dict, is_in_full: bool) -> list[str]:
    """One log entry: its topic line, and with is_in_full its Done/Found/Decided."""
    repos = ", ".join(
        f"`{repo.removeprefix('GitHub/')}`" for repo in entry_repos(entry)
    )
    lines = [f"- {format_time(entry['end'])} · {repos} · {entry['topic']}"]
    if is_in_full:
        lines += [
            f"  - Done: {done['text']} {' '.join(done['commits'])}".rstrip()
            for done in entry["done"]
        ]
        lines += [f"  - Found: {found['text']}" for found in entry["found"]]
        lines += [f"  - Decided: {decided}" for decided in entry["decided"]]
        lines += [f"  - Remember: {fact}" for fact in entry.get("remember", [])]
    return lines


def main() -> None:
    """Gather everything, print the report and the context, record the run."""
    is_all, selection, project_filter = parse_arguments(sys.argv[1:])
    current_scope = scope_of(Path.cwd())
    is_local = not is_all and not project_filter and current_scope != GLOBAL_SCOPE
    if is_local:
        project_filter = current_scope
    run_time = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    projects = collect_projects(project_filter) or (
        [Project(current_scope)] if is_local else []
    )
    needs_you_projects = projects + (read_global_project() if is_local else [])
    entries, log_title = read_log_entries(selection, project_filter)
    running = ([] if project_filter else collect_live_sessions()) + collect_local_state(
        project_filter
    )
    is_in_full = bool(project_filter)

    title = f"Debrief: {project_filter}" if project_filter else "Debrief"
    report = [f"## {title} · {format_time(run_time)}", ""]

    def add_section(heading: str, lines: list[str]) -> None:
        if lines:
            report.extend([f"**{heading}**", "", *lines, ""])

    add_section(
        "Needs you",
        render_needs_you(needs_you_projects)
        + render_memory_line(project_filter)
        + render_stale_notes_line(project_filter)
        + render_memo_sync_line()
        + render_knowledge_failures()
        + render_dream_line()
        + render_backup_line(),
    )
    add_section("Running now", running)
    if LOG_ENTRIES.exists() and (entries or selection == "last"):
        add_section(
            f"Log ({log_title})",
            [line for entry in entries for line in render_entry(entry, is_in_full)]
            or ["- Nothing logged."],
        )
    if not project_filter:
        add_section(
            "Knowledge (changed since the last debrief)", render_knowledge_changes()
        )
    if is_in_full:
        for project in projects:
            report.extend(render_project_in_full(project))
    else:
        add_section("Projects", [render_project_line(project) for project in projects])
    if len(report) == 2:
        report.append("Nothing open, nothing running.")

    print("\n".join(report).rstrip())
    print(f"\n{CONTEXT_MARKER}")
    if not LOG_ENTRIES.exists():
        print("No log on this machine.")
    for entry in entries:
        print("\n".join(render_entry(entry, is_in_full=True)))

    if not project_filter:
        LAST_DEBRIEF_FILE.parent.mkdir(parents=True, exist_ok=True)
        LAST_DEBRIEF_FILE.write_text(run_time + "\n")


if __name__ == "__main__":
    main()

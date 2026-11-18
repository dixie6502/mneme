#!/usr/bin/env python3
"""Print the /debrief report: what needs the user, what runs now, the log, projects.

Usage: report.py [all] [last|N] [filter]
  all     every project, even when run inside one
  last    log entries since the previous `all` debrief
  N       the latest N log entries (default 3)
  filter  substring of a project scope (e.g. dixie6502/construct): that project in full

Run inside a folder with a folio notebook without `all` or a filter, it is local:
the filter is that notebook's id (`folio --dir`), matched as a whole scope, so
owner/repo leaves out owner/repo-other. Filters match case-insensitively (store
notebook ids are lowercased, as repositories are matched).

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
import shutil
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime
from functools import cache
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
# Data of the memo plugin, kept in folio's notebooks: a store is a notebooks/
# folder holding a .folio marker in an owner folder (~/<host>/<owner>/), with
# one notebook per project; a local notebook is a notes/ folder inside the
# folder it serves. Each notebook holds a .notebook marker, its TODO.md, item
# details under todo/, and notes (a `created:` frontmatter date, else the
# file's mtime, stale after 28 days). `folio check` reports their problems,
# sync included.
STORE_DIR = "notebooks"
STORE_MARKER = ".folio"
NOTEBOOK_MARKER = ".notebook"
LOCAL_NOTEBOOK_DIR = "notes"
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
    """Everything known about one project, keyed by its notebook id (owner/repo, lowercased)."""

    name: str
    todo: dict[str, list[TodoItem]] = field(default_factory=dict)
    issues: list[dict] = field(default_factory=list)
    is_issues_unreadable: bool = False


@cache
def clone_paths(pattern: str) -> tuple[Path, ...]:
    """Matches of a glob under $HOME. Hidden top-level folders (.cache, .local, ...)
    are skipped without descending into them: they hold most of a home's folders."""
    top_pattern, _, rest = pattern.partition("/")
    tops = [top for top in HOME.glob(top_pattern) if not top.name.startswith(".")]
    return tuple(
        sorted(path for top in tops for path in (top.glob(rest) if rest else [top]))
    )


def notebook_id(notebook: Path) -> str:
    """A notebook's id: <owner>/<project> in a store (lowercased, as repos are
    matched), the served folder's path from ~ for a local notebook, else ""."""
    store = notebook.parent
    if store.name == STORE_DIR and (store / STORE_MARKER).is_file():
        return f"{store.parent.name}/{notebook.name}".lower()
    if notebook.name == LOCAL_NOTEBOOK_DIR and notebook.parent.is_relative_to(HOME):
        return str(notebook.parent.relative_to(HOME))
    return ""


def current_notebook_id() -> str:
    """Id of the current folder's folio notebook (`folio --dir`), or "" if none."""
    if not shutil.which("folio"):
        return ""
    notebook = run(["folio", "--dir"]).strip()
    return notebook_id(Path(notebook).resolve()) if notebook else ""


def is_listed(relative: Path) -> bool:
    """False for paths folio leaves out: any part hidden (.*) or skipped (_*)."""
    return not any(part.startswith((".", "_")) for part in relative.parts)


def list_notebooks() -> list[tuple[str, Path]]:
    """(id, folder) of every notebook in every store, sorted by id. Local
    notebooks are not listed: nothing records where they are."""
    return sorted(
        (notebook_id(notebook), notebook)
        for marker in clone_paths(f"*/*/{STORE_DIR}/{STORE_MARKER}")
        for notebook in marker.parent.iterdir()
        if notebook.is_dir()
        and is_listed(Path(notebook.name))
        and (notebook / NOTEBOOK_MARKER).is_file()
    )


def notebook_notes(notebook: Path) -> list[Path]:
    """A notebook's notes: its markdown files but TODO.md and item details (todo/)."""
    notes = []
    for note in notebook.rglob("*.md"):
        relative = note.relative_to(notebook)
        if relative == Path("TODO.md") or relative.parts[0] == "todo":
            continue
        if is_listed(relative):
            notes.append(note)
    return notes


def run(command: list[str]) -> str:
    """Run a command and return its stdout, or "" if it fails."""
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    return result.stdout if result.returncode == 0 else ""


def read_last_debrief() -> str:
    """Time of the previous unfiltered debrief (ISO UTC), or "" if none recorded."""
    return LAST_DEBRIEF_FILE.read_text().strip() if LAST_DEBRIEF_FILE.exists() else ""


def days_since(timestamp: float) -> int:
    """Whole days elapsed since a Unix time."""
    return int((datetime.now().timestamp() - timestamp) / SECONDS_PER_DAY)


def display_name(path: str) -> str:
    """A path from ~ as shown in the report: GitHub clones without the host, ~ for home
    (relative ".", or absolute in entries logged from ~)."""
    return "~" if path in (".", str(HOME)) else path.removeprefix("GitHub/")


def scope_pattern(project_filter: str, is_whole_scope: bool) -> re.Pattern[str]:
    """The filter as a pattern over names, ignoring case (folio lowercases repos): a
    substring, or the whole scope at the end of a name (GitHub/owner/repo)."""
    text = re.escape(project_filter)
    return re.compile(rf"(^|/){text}$" if is_whole_scope else text, re.IGNORECASE)


def matches(project_pattern: re.Pattern[str], name: str) -> bool:
    """True when the name matches the project filter's pattern."""
    return bool(project_pattern.search(name))


def parse_arguments(arguments: list[str]) -> tuple[bool, str, str]:
    """Split the arguments into `all`, the log selection (last, N or "") and the filter."""
    is_all = bool(arguments) and arguments[0] == "all"
    if is_all:
        arguments = arguments[1:]
    selection = ""
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


def collect_projects(project_pattern: re.Pattern[str]) -> list[Project]:
    """Projects with a TODO.md in a folio notebook or a GitHub clone, matching the filter."""
    projects: dict[str, Project] = {}

    def project_at(scope: str) -> Project:
        return projects.setdefault(scope, Project(scope))

    for notebook_id, notebook in list_notebooks():
        todo_file = notebook / "TODO.md"
        if todo_file.exists() and matches(project_pattern, notebook_id):
            project_at(notebook_id).todo = read_todo(todo_file)
    clones = [
        str(git.parent.relative_to(HOME / "GitHub")).lower()  # as folio ids repos
        for git in clone_paths("GitHub/*/*/.git")
    ]
    clones = [scope for scope in clones if matches(project_pattern, scope)]
    with ThreadPoolExecutor() as pool:
        results = pool.map(read_issues, clones)
        for scope, (issues, is_unreadable) in zip(clones, results, strict=True):
            if issues or is_unreadable:
                project_at(scope).issues = issues
                project_at(scope).is_issues_unreadable = is_unreadable
    return sorted(projects.values(), key=lambda project: project.name)


def is_waiting_on_user(issue: dict) -> bool:
    """An issue labelled `user` waits on the user."""
    return any(label["name"] == "user" for label in issue["labels"])


def read_log_entries(
    selection: str, project_pattern: re.Pattern[str]
) -> tuple[list[dict], str]:
    """The log entries to show, and the section title describing them."""
    entries = []
    if LOG_ENTRIES.exists():
        entries = [
            json.loads(line) for line in LOG_ENTRIES.read_text().splitlines() if line
        ]
    entries = [
        entry
        for entry in entries
        if any(matches(project_pattern, repo) for repo in entry_repos(entry))
    ]
    entries.sort(key=lambda entry: entry["end"])
    if selection == "last":
        since = read_last_debrief()
        if since:
            shown = [entry for entry in entries if entry["end"] > since]
            return shown, f"since the last debrief, {format_time(since)}"
        latest = entries[-DEFAULT_ENTRIES_SHOWN:]
        return latest, f"latest {DEFAULT_ENTRIES_SHOWN}, no previous debrief recorded"
    count = int(selection) if selection else DEFAULT_ENTRIES_SHOWN
    return entries[-count:], f"latest {count}"


def entry_repos(entry: dict) -> list[str]:
    """Projects an entry touched; entries before the repos field use their directory."""
    return entry.get("repos") or [entry["cwd"].removeprefix(f"{HOME}/")]


def format_time(timestamp: str) -> str:
    """ISO UTC timestamp as 'MM-DD HH:MM UTC'."""
    return f"{timestamp[5:10]} {timestamp[11:16]} UTC"


def collect_local_state(project_pattern: re.Pattern[str]) -> list[str]:
    """One line per clone with uncommitted or unpushed work."""
    lines = []
    for git in clone_paths("*/*/*/.git"):
        path = str(git.parent.relative_to(HOME))
        if not matches(project_pattern, path):
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
                f"- `{display_name(path)}`: {changed} uncommitted, {unpushed_text}"
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


def render_memory_line(project_pattern: re.Pattern[str]) -> list[str]:
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
        name = display_name(name)
        if not matches(project_pattern, name):
            continue
        oldest_days = days_since(min(note.stat().st_mtime for note in notes))
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
    return days_since(created.timestamp() if created else note.stat().st_mtime)


def render_stale_notes_line(project_pattern: re.Pattern[str]) -> list[str]:
    """One line listing notebooks with stale notes, to convert into docs or delete."""
    parts = []
    for name, notebook in list_notebooks():
        if not matches(project_pattern, name):
            continue
        ages = [note_age_days(note) for note in notebook_notes(notebook)]
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
    since = read_last_debrief()
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
    to_review = Counter(
        proposal["layer"] for proposal in proposals if proposal.get("status") == "open"
    )
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


def render_folio_check_lines() -> list[str]:
    """`folio check` findings (notebooks and their sync), one line each."""
    if not shutil.which("folio"):
        return []
    result = subprocess.run(
        ["folio", "check"], capture_output=True, text=True, check=False
    )
    if result.returncode == 0:
        return []
    return [f"- Folio: {line}" for line in result.stdout.splitlines() if line]


def render_backup_line() -> list[str]:
    """One line when the log runs here and its backup is unconfigured or too old."""
    if not LOG_ENTRIES.exists():
        return []
    if not os.environ.get("MEMEX_BACKUP_DIR"):
        return ["- Backup: not configured, transcripts exist only on this host"]
    see_log = f"see `~/{RUN_LOG.relative_to(HOME)}`"
    if not LAST_BACKUP_FILE.exists():
        return [f"- Backup: no success yet, {see_log}"]
    age_days = days_since(LAST_BACKUP_FILE.stat().st_mtime)
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
    remaining_next = len(upcoming) if now else max(len(upcoming) - 1, 0)
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
    repos = ", ".join(f"`{display_name(repo)}`" for repo in entry_repos(entry))
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
    current_id = current_notebook_id()
    is_local = not is_all and not project_filter and bool(current_id)
    if is_local:
        project_filter = current_id
    project_pattern = scope_pattern(project_filter, is_whole_scope=is_local)
    run_time = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    projects = collect_projects(project_pattern) or (
        [Project(current_id)] if is_local else []
    )
    entries, log_title = read_log_entries(selection, project_pattern)
    running = ([] if project_filter else collect_live_sessions()) + collect_local_state(
        project_pattern
    )
    is_in_full = bool(project_filter)

    title = f"Debrief: {project_filter}" if project_filter else "Debrief"
    report = [f"## {title} · {format_time(run_time)}", ""]

    def add_section(heading: str, lines: list[str]) -> None:
        if lines:
            report.extend([f"**{heading}**", "", *lines, ""])

    add_section(
        "Needs you",
        render_needs_you(projects)
        + render_memory_line(project_pattern)
        + render_stale_notes_line(project_pattern)
        + render_folio_check_lines()
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

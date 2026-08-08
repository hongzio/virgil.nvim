---
name: virgil
description: Leave and read code notes in a running Neovim (virgil.nvim RPC). Use when pinning a finding from reading code or reviewing a diff onto the screen the human is actually looking at, when checking notes left earlier, or when driving the human's cursor to a specific file and line.
---

# virgil — leaving notes on code

virgil floats notes above code lines in the Neovim buffer a human is looking at. Notes
live on disk (`<git-common-dir>/virgil/notes.json`) and follow the code as it changes.
Instead of listing findings in a chat window, you pin them **next to the code**.

## 1. Find the socket

virgil opens an RPC socket per Neovim instance. The first instance takes the canonical
path; later ones fall back to `<path>.<pid>`. Only live ones matter — **check which
repository an instance is attached to before picking it.**

```bash
for s in "${XDG_RUNTIME_DIR:-$TMPDIR}"/virgil*.sock*; do
  [ -e "$s" ] || continue
  root=$(nvim --server "$s" --remote-expr "json_encode(v:lua.require'virgil'.status().repo.root)" 2>/dev/null) \
    && echo "live $s -> $root"
done
```

Once you have picked one, hold it in `SOCK`. A human can run `:Virgil socket` to print
their own instance's path. `nvim --serverlist` does not exist in Neovim — don't use it.

## 2. Call convention

```bash
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.<fn>(<args>))"
```

- Wrapping in `json_encode(...)` gives you a single parseable line. Do it by habit.
- **The expression must be one line.** A newline anywhere gives `E15: Invalid expression`.
- Arguments are Vimscript dict literals: `{'line': 12, 'summary': '…'}`.
- **Double every single quote.** `'isn''t'` → `isn't`.
- Returned lists are **0-based** on the Vim side: `notes({})[0]` is the first note.
- On failure you get `null` or `false`, and the human sees a notification. Nothing fails silently.

For long text with quotes in it, **pass a file.** Escaping disappears entirely:

```bash
cat > /tmp/payload.json <<'JSON'
{"path": "bot.go", "line": 9,
 "summary": "don't conflate \"empty\" with \"error\"",
 "rationale": "Callers can't tell a failure from a legitimately empty id.\nNewlines survive too.",
 "author": "claude"}
JSON
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.note(json_decode(join(readfile('/tmp/payload.json'), ''))))"
```

Single quotes, double quotes, newlines, non-ASCII — none of them are a problem. Make this
the default form for anything beyond a short, simple note.

## 3. Always start with `status()`

Writing a note without knowing what is on screen anchors it to the wrong content.

```bash
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.status())"
```

```json
{"view": {"kind": "file", "path": "bot.go", "address": "blob:fe35c13fd6f6", "lines": 10,
          "file": "/repo/bot.go"},
 "repo": {"root": "/repo", "common_dir": "/repo/.git"},
 "cursor": {"line": 1, "col": 1}, "notes": {"total": 0, "visible": 0},
 "visibility": "default", "socket": "…"}
```

- `view.path` — repo-relative path. Give a note's `path` in the same form.
- `view.address` — `blob:<sha>` means committed content (an immutable address);
  `worktree:<path>` means content not committed yet. This decides where a note anchors.
- `view.kind == "blob"` means the human is looking at the **old-revision side** of a window.
- A `review` key means a review is open (§7).

## 4. Writing a note

```bash
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.note({'path': 'bot.go', 'line': 6, 'summary': 'id''s zero case isn''t handled', 'author': 'claude'}))"
```

One line is the only hard rule. If the rationale is long or has quotes in it, use the file
form from §2.

| Field | |
|---|---|
| `summary` | **Required.** One-line point. Without it a prompt opens for the human and you get nothing back |
| `rationale` | Why, with the evidence. Multiple lines are fine |
| `path` | Omitted means the buffer the human is currently looking at. Prefer a repo-relative path |
| `line` / `end_line` | 1-based. Omitting `end_line` means a single line |
| `author` | Put your name here. Keeps your notes distinct from a human's |

**`line` means "that line in that file right now."** Not a line number from diff output,
not one from a version you read earlier. Given a `path`, virgil opens the current on-disk
content and anchors there. When unsure, check the target file's current state with
`notes()` or `status()` first.

The return value carries `id` and `anchor`. Checking that `anchor.text` is the line you
meant catches a misplaced note immediately.

## 5. What is worth a note

This matters more than anything else here. A note belongs **between a code comment and chat**.

Leave one for:
- *An observation that is true of this code right now* — "this lock is taken in one place but released on two paths"
- A suspicion you haven't confirmed — "this condition looks like it retries four times; needs checking"
- Something to check next — "three callers of this function, none of them nil-check"
- A problem found in review, with the evidence for it

Don't leave one for:
- A permanent fact the team should share → that belongs in a code comment or the docs
- Anything obvious from reading the code ("this function returns a string")
- Mechanical one-note-per-file filler. The moment notes become background noise, the human turns them all off
- An explanation of something you just fixed. That's a commit message

Treat two or three notes per screen as the ceiling. A finding that would take twenty notes
isn't a note, it's a report — summarize it in chat instead.

`rationale` should hold **evidence, not a verdict**. Not "this is dangerous" but
"reconcile() touches b.seq from another goroutine without the mutex".

## 6. Many at once

For several notes, a sidecar JSON file avoids quoting hell.

```bash
cat > /tmp/notes.json <<'JSON'
{"files": [{"path": "bot.go", "annotations": [
  {"newRange": {"start": 9, "end": 9}, "summary": "…", "rationale": "…"},
  {"newRange": {"start": 5, "end": 5}, "summary": "…", "rationale": "…"}]}]}
JSON
nvim --server "$SOCK" --remote-expr "v:lua.require'virgil'.import({'file': '/tmp/notes.json', 'author': 'claude'})"
```

Incoming line numbers anchor against each file's **current content**. The return value is
the number of notes imported. The other direction (`export`) takes
`{'format': 'agent-context', 'out': '/tmp/out.json'}`.

## 7. If a review is open

```bash
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.review({'base': 'origin/main'}))"
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.files())"
```

`review()` spreads a changeset into per-file diff tabs (omitting `head` means the working
tree). `files()` returns `[{path, status, added, removed, notes}]` — use it to choose where
to start.

Notes written while a review is open record their origin automatically:

```json
{"review": "origin/main..pr-1", "base": "9f3c1ab…", "base_ref": "origin/main",
 "head": "abc1234…", "head_ref": "pr-1",
 "hunk_header": "@@ -6,2 +6,2 @@ func mint(id int) string {"}
```

`review` is the label a human reads; `base` and `head` are the commits it resolved to at
the time. Refs move, so only the commits identify the changeset later — `head` is absent
when the review was against the working tree. `notes({'review': …})` accepts either
spelling and matches on commits, so `origin/main..pr-1` finds notes recorded as
`main..abc1234`.

This **takes no part in position calculation.** It only records which change the note came
out of. To turn a note into a permanent one unrelated to the review, break that link with
`keep(id)`.

## 8. Check existing notes first

Don't pin the same point twice. Notes accumulate across sessions.

```bash
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.notes({'status': 'open'}))"
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.notes({'path': 'bot.go'}))"
```

Each entry carries the stored `anchor` plus a `projected` position for the current view:

- `projected.status == "ok"` — sitting exactly on its line
- `"stale"` — the line changed after the note was written. Time to re-read it and `update` or `resolve`
- `"orphan"` — the anchored content can't be found (an abandoned commit, say)
- No `projected` at all means that content isn't in the current view (a deleted line, for instance)

## 9. Amending and closing

```bash
… .update('n-abc', {'summary': '…', 'rationale': '…'})   # reword
… .resolve('n-abc')      # handled → hidden from the default view. The record stays
… .unresolve('n-abc')
… .keep('n-abc')         # break the review-origin link, making it permanent
… .remove('n-abc')       # delete. Irreversible — only remove what you created
```

`resolve`/`unresolve`/`remove`/`keep` also take id lists: `resolve(['n-a', 'n-b'])`.

## 10. Moving the human's screen

To put the code you're describing in front of them:

```bash
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.open('bot.go', {'line': 6}))"
```

Passing `rev` opens that revision's content read-only: `{'line': 6, 'rev': 'HEAD~3'}`.
The return value is the post-jump `status()`, so you can confirm it landed. The human may
be in the middle of editing — move them **only when it matters**.

## 11. When things fail

| Symptom | Meaning |
|---|---|
| `note()` returns `null` | That path isn't in the repo, or the file doesn't exist. Check it's relative to `status().repo.root` |
| `status().view.kind == "none"` | The human isn't in a file buffer (a terminal, a picker). Attach with an explicit `path` |
| `remove()` returns `false` | No such id |
| Socket connection fails | That instance is dead. Find one again via §1 |
| Outside a repo | virgil only works inside a git repository |

**No failure ever silently deletes a note.** When a position can't be found, it is marked
`stale`/`orphan` and shown to the human.

## 12. Checklist

Before leaving a note:

1. `status()` told me the repo, the file, and the content address
2. `notes({'path': …})` showed me whether this point already exists
3. `summary` is one line, and `rationale` holds evidence rather than a verdict
4. This is **not** a permanent fact that belongs in a code comment
5. `author` carries my name
6. The returned `anchor.text` is the line I meant

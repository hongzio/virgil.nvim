# virgil.nvim
A Neovim plugin for attaching notes to code. Reading code, reading a diff between two
commits, reading changes you haven't committed yet — the same way of leaving a note works
in all three. Notes live on disk, follow the code as it changes, and can be written and
read by external agents over RPC.

```
  5 // mintMakerOrderID returns a fresh id for a maker order.
    ┌─ ● seq is not synchronised ───────────────────────────── claude ─┐
    │ reconcile() runs on another goroutine and touches b.seq without  │
    │ the mutex; two makers can mint the same id under load.           │
    └──────────────────────────────────────────────────────────────────┘
  6 func (b *Bot) mintMakerOrderID() string {
  7         if b.cfg.OriginID != 0 {
```

Notes appear as `virt_lines` **directly above the code line**. They never touch the real
text, so line numbers don't shift and diff alignment doesn't break. The box aligns to the
code's indentation, and the summary rides in the top border, so a note without a rationale
is two lines total. When the window is too narrow to fit the summary in the border, it
drops into the body — nothing is ever truncated, and nothing overflows the window.

## Install

```lua
vim.pack.add({ "https://github.com/hongzio/virgil.nvim" })
```

Calling `setup()` is optional. The defaults work on their own.

Requires Neovim 0.10+ (0.12 recommended — its default `diffopt` is
`inline:char,linematch:40`) and git. There are no hard dependencies: `fzf-lua` /
`snacks.nvim` are used as the picker if present, otherwise it falls back to quickfix.

## Usage

```vim
:Virgil note             " write a note on the current line (or visual selection)
:Virgil notes            " list notes
:Virgil toggle           " cycle visibility: default → all → off
:Virgil resolve          " resolve the note near the cursor
:Virgil keep             " break a note's origin link, making it permanent
:Virgil review [base] [head]   " open a changeset as diff tabs; with no arguments, pick one
:Virgil files            " changed-file picker
:Virgil sidebar          " toggle the review's changed-file list
:Virgil export [path] [format] " export notes (agent-context | json | markdown)
:Virgil import [path]    " read in external notes
:Virgil prune            " clean up notes that lost their position
:Virgil socket           " print this instance's RPC socket path
:Virgil quit             " tear down review tabs
```

In the compose window the first non-empty line is the summary and everything below it is
the rationale. `<C-s>` saves, `q` cancels.

In the `:Virgil notes` list (when using fzf-lua):

| Key | Action |
|---|---|
| `<CR>` | jump to the note |
| `<C-r>` | resolve the note |
| `<C-x>` | **delete the note** (irreversible) |

Selecting several rows with `<Tab>` acts on all of them at once. fzf-lua's default `<C-x>`
only drops a row from the temporary list (the note itself survives) while the header says
"delete", which is easy to misread — so it was rebound to do what the header says. When
the picker falls back to snacks or quickfix these actions aren't available and only the
jump works.

### Keymaps

No default keymaps are installed; only `<Plug>` mappings are provided. Suggested:

```lua
vim.keymap.set({ 'n', 'x' }, '<localleader>n', '<Plug>(virgil-note)')
vim.keymap.set('n', ']n', '<Plug>(virgil-next-note)')
vim.keymap.set('n', '[n', '<Plug>(virgil-prev-note)')
vim.keymap.set('n', '<localleader>r', '<Plug>(virgil-resolve)')
vim.keymap.set('n', '<localleader>k', '<Plug>(virgil-keep)')
vim.keymap.set('n', '<localleader>t', '<Plug>(virgil-toggle)')
vim.keymap.set('n', ']f', '<Plug>(virgil-next-file)')
vim.keymap.set('n', '[f', '<Plug>(virgil-prev-file)')
vim.keymap.set('n', '<localleader>s', '<Plug>(virgil-sidebar)')
```

Hunk navigation uses diff mode's built-in `]c` / `[c` as-is.

### Review

`:Virgil review origin/main` spreads a changeset into per-file diff tabs. Tabs are created
on visit — a 200-file review does not open 200 tabs up front. `]f` / `[f` move between
files, `:Virgil files` picks any file directly, and `:Virgil quit` cleans everything up.

`:Virgil sidebar` puts the whole changeset beside the diff, one row per file:

```
▸ M README.md               +26 -1  31♦
  M lua/virgil/git.lua           +59 -0
  M lua/virgil/review.lua      +319 -10
```

`<CR>` opens a row, `q` closes the list. Because a review is one tab per file, this is one
window per tab over a **single shared buffer** — what differs between tabs is which row
carries the `▸`, and that is a redraw rather than another window's worth of state. Turning
it off closes it in every tab at once, including the ones you have not visited: a list left
standing in a tab you later walk into reads as the toggle having failed. It is off by
default (`review.sidebar = true` opens it with every review, `review.sidebar_width` sets
the column).

With no arguments it asks which changeset instead: what is uncommitted, **the reviews that
already hold notes**, what this branch adds over the one it tracks, and recent commits
against their parents. The middle one is the point — after an agent leaves notes on a
changeset, that changeset is a list entry rather than a pair of revisions you have to
remember. The last row hands you the command line, where ref completion already works. It
is `vim.ui.select`, so whatever picker you have configured is the one you get.

With two commits the diff is taken from where their histories parted, git's
`base...head` — the same range a forge shows for a pull request, and what the review spec
prints. Measuring from the tip of the base branch instead would fold every commit the base
gained since the branch point into the review, backwards: files the change never touched,
listed as though it reverted them. A review against the working tree keeps the plain
two-dot `base..worktree`; there is no second commit to part from.

The left side is a read-only scratch buffer holding the old revision's blob; the right side
is **the real file on disk**. That means on the right, `gd` (go to definition), finding
references, and fixing and saving in place all work exactly as they normally do. This
asymmetry is the reason this plugin exists.

A note is drawn on **exactly one side** — whichever side still holds the line it was
written on. A note on rewritten code stays on the left; a note on new code appears only on
the right; a note on a line the changeset never touched goes to the new side, since that is
the real file. Only when neither side kept the line intact does the content address decide.
On a screen showing the same line side by side in two windows, drawing the note twice is
unreadable — and worse, on the opposite side that line sits inside a hunk and would read as
`stale`, which isn't true: nothing has changed since the note was written, you are just
looking at a different revision.

The choice is made **per line, not per file**. Addressing alone would be simpler, but a
file's sha changes the moment you fix a typo anywhere in it, and every note in that file
would march over to the old side at once. Splitting sides also stops the moment the other
half leaves the screen: handing a note to a window nobody is looking at is
indistinguishable from losing it.

A note written inside a review records where it came from: the label you typed
(`origin/main..pr-1`), and the two commits that label resolved to. Refs move — `HEAD` moves
with every commit, a branch moves with every fetch — so the label alone cannot name that
changeset again tomorrow, and only the commits can. Two reviews of the same commits are
therefore one review however they were spelled, which is what `notes({ review = … })`
matches on and what decides whether a note is drawn as this screen's own or as background.
None of it takes part in position calculation; that is the anchor's job alone.

One review per instance. Starting a new one tears down the previous review's tabs.

## Agents

Neovim opens a socket and agents call the same API over `--remote-expr`. There is no
separate daemon.

```bash
SOCK=$(nvim --server "$VIRGIL_SOCK" --remote-expr "v:lua.require'virgil'.socket()")

# what is on screen right now — the first thing an agent should call
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.status())"

# attach a note (anchored to the current view's content address)
nvim --server "$SOCK" --remote-expr \
  "json_encode(v:lua.require'virgil'.note({'line': 1036, 'summary': '…', 'rationale': '…', 'author': 'claude'}))"

# move the screen
nvim --server "$SOCK" --remote-expr "v:lua.require'virgil'.open('internal/bot.go', {'line': 1036})"

# read
nvim --server "$SOCK" --remote-expr "json_encode(v:lua.require'virgil'.notes({'status': 'open'}))"
```

Wrapping a call in `json_encode()` turns any result into a single easily parsed line.

Temna o hand an agent is [SKILL.md](SKILL.md) — finding the socket, quoting rules,
and what is and isn't worth a note. For Claude Code you can mount it as a skill directly:

```sh
mkdir -p .claude/skills/virgil && ln -s ../../../SKILL.md .claude/skills/virgil/SKILL.md
```

The socket path comes from `vim.g.virgil_socket`, or defaults to
`$XDG_RUNTIME_DIR/virgil.sock` (`$TMPDIR/virgil-$USER.sock` on macOS). If another instance
already holds that path, this one falls back to `<path>.<pid>`. Socket files left behind by
dead instances are cleaned up automatically. `:Virgil socket` prints the current instance's
path and also puts it on the `+` clipboard.

### Lua API

```lua
local virgil = require('virgil')

virgil.status()                    -- current view's content address, path, cursor, visible note count
virgil.note({ path, line, end_line, summary, rationale, author })
virgil.notes({ path, status, review, id })  -- stored anchor + projection into the current view
virgil.update(id, { summary = '…' })
virgil.open(path, { line = 1036, rev = nil })
virgil.keep(id) / virgil.resolve(id) / virgil.unresolve(id) / virgil.wontfix(id) / virgil.remove(id)
                                   -- id also accepts a { id1, id2 } list. Omit it for the note under the cursor
virgil.next_note() / virgil.prev_note()
virgil.toggle('all')
virgil.review({ base = 'origin/main', head = nil, paths = { 'internal/' } })
virgil.files()
virgil.export({ format = 'agent-context', review = '…', out = '/path.json' })
virgil.import({ file = '/path.json' })
virgil.prune({ dry_run = true })
```

Given a `summary`, `note()` saves immediately without opening a window. Omit it and the
compose window opens.

## Where notes live

One file: `<git-common-dir>/virgil/notes.json`. Being inside `.git` keeps the working tree
clean, keeps notes from propagating through clones, and collects notes in one place even
across multiple worktrees. A `blob` anchor stores `(blob_sha, line)` — an address that
never moves. A `worktree` anchor stores `(path, line)` plus one extra field, `anchor.hash`,
the hash of the content at the time the note was written; it is used for anchor hardening
(promotion to a `blob` anchor once that content is committed) and for finding
not-yet-committed content again.

Notes are personal by default. Handing them to the team takes an explicit `:Virgil export`.
A permanent fact the team should share belongs in a code comment or the docs — a note's
place is *an observation that is true for me right now*, a suspicion not yet confirmed, or
something to check next.

## Configuration

```lua
require('virgil').setup({
  author = nil,          -- name stamped on notes (default: $USER)
  context_lines = 3,     -- fallback context lines recorded around the anchor
  visibility = 'default',-- 'default' | 'all' | 'off'
  picker = 'auto',       -- 'auto' | 'fzf-lua' | 'snacks' | 'quickfix'
  render = {
    -- 'single' | 'rounded' | 'double' | 'heavy' | 'bar' | 'none'
    -- or 8 characters in nvim_open_win order
    border = 'single',
    prefix = '▏',        -- the margin bar used when border = 'bar'
    icon = '●',
    max_width = 100,
    show_author = true,
    show_rationale = true,
    align_indent = true, -- align the note block to the code's indentation
  },
  review = {
    layout = 'vertical', -- 'vertical' | 'horizontal'
    highlight = 'syntax',-- 'syntax' | 'filetype' | false
    sidebar = false,     -- open the changed-file list with every review
    sidebar_width = 40,
  },
  socket = { enable = true, path = nil },
  prune = { orphan_days = 30, resolved_days = 90 },
})
```

Highlight groups (all `default` links, so a colorscheme wins):
`VirgilBorder` `VirgilSign` `VirgilIcon` `VirgilSummary` `VirgilRationale`
`VirgilAuthor` `VirgilStale` `VirgilOrphan` `VirgilResolved` `VirgilDim`.

## When a note drifts

- **stale** — it projected, but the line itself changed. The original text (`~ …`) is shown
  alongside the position.
- **orphan** — the anchored content can't be obtained at all (e.g. the blob of an abandoned
  commit was GC'd). virgil searches using the recorded original text and its surrounding
  context, and leaves it as an orphan if that fails.

**No failure ever silently deletes a note.** Seeing one drift is better than losing it, and
the drift itself is the signal that the code changed underneath it.

## Design decisions

| Question | What this implementation chose |
|---|---|
| Ambiguity in fallback search | Require an exact match on the original text (retrying whitespace-insensitively on failure), then score candidates by how many of the recorded 3 context lines above and below are still attached. Nearer lines weigh more, and ties go to the candidate closest to the recorded line |
| Projection cache invalidation | Cache per `changedtick`, with rendering debounced at 60ms. When the anchor content and the view content are identical, `vim.diff` is skipped entirely |
| Note cleanup policy | `prune` only removes notes that have been unlocatable for 30 days and notes closed for 90 days. The command asks for confirmation before deleting |
| Concurrent reviews | One per instance. A new review tears down the previous review's tabs on the way in |
| Filetype of the left-hand blob | `filetype` is left unset and only treesitter (or `syntax` if unavailable) is enabled. You get highlighting without a language server attaching to a buffer that has no file. Change it with `review.highlight = 'filetype'` |
| Socket lifetime | The first instance takes the canonical path; later ones fall back to `<path>.<pid>`. Socket files from dead instances are cleaned up automatically |
| Telling agent notes from human ones | It goes no further than stamping the name (`author`) dimly in the note's header. Colors aren't split because the distinction that matters is not "who wrote it" but "is this about the change in front of me" — and emphasis versus dimming already carries that |

## Tests

```sh
nvim --clean -l tests/run.lua
```

The suite covers anchoring and projection, persistence across a real second Neovim process,
diff-pair ownership in review, and rendering geometry in narrow windows.

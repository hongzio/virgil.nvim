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
`snacks.nvim` are used as the picker if present, otherwise it falls back to quickfix, and
`gh` adds pull requests to the changeset picker if you happen to have it.

## Usage

```vim
:Virgil note             " write a note on the current line (or visual selection)
:Virgil notes            " list notes
:Virgil toggle           " cycle visibility: default → all → off
:Virgil remove           " delete the note near the cursor (irreversible)
:Virgil review [base] [head]   " open a changeset as diff tabs; with no arguments, pick one
:Virgil files            " changed-file picker
:Virgil sidebar          " toggle the changeset's changed-file list
:Virgil export [path] [format] " export notes (agent-context | json | markdown)
:Virgil import [path]    " read in external notes
:Virgil prune            " clean up notes that lost their position
:Virgil socket           " print this instance's RPC socket path
:Virgil quit             " tear down changeset tabs
```

In the compose window the first non-empty line is the summary and everything below it is
the rationale. `<C-s>` saves, `q` cancels.

In the `:Virgil notes` list (when using fzf-lua):

| Key | Action |
|---|---|
| `<CR>` | jump to the note |
| `<C-x>` | **delete the note** (irreversible) |

Selecting several rows with `<Tab>` acts on all of them at once. fzf-lua's default `<C-x>`
only drops a row from the temporary list (the note itself survives) while the header says
"delete", which is easy to misread — so it was rebound to do what the header says. When
the picker falls back to snacks or quickfix these actions aren't available and only the
jump works.

### Keymaps

No default keymaps are installed. `<Plug>` mappings exist for the things that act on a
note; everything else is a `:Virgil` subcommand and maps just as well. One prefix for the
lot, and the pairs on brackets:

```lua
local map = vim.keymap.set

map({ 'n', 'x' }, '<leader>vv', '<Plug>(virgil-note)',    { desc = 'Virgil note' })
map('n', '<leader>vx', '<Plug>(virgil-remove)',           { desc = 'Virgil delete note at cursor' })
map('n', '<leader>vt', '<Plug>(virgil-toggle)',           { desc = 'Virgil toggle visibility' })
map('n', '<leader>vl', '<Cmd>Virgil notes<CR>',           { desc = 'Virgil list notes' })

map('n', '<leader>vd', '<Cmd>Virgil review<CR>',          { desc = 'Virgil pick a changeset' })
map('n', '<leader>vR', '<Cmd>Virgil review HEAD<CR>',     { desc = 'Virgil review worktree' })
map('n', '<leader>vf', '<Cmd>Virgil files<CR>',           { desc = 'Virgil changed files' })
map('n', '<leader>vs', '<Cmd>Virgil sidebar<CR>',         { desc = 'Virgil toggle file list' })
map('n', '<leader>vq', '<Cmd>Virgil quit<CR>',            { desc = 'Virgil close changeset tabs' })

map('n', ']n', '<Plug>(virgil-next-note)',                { desc = 'Next virgil note' })
map('n', '[n', '<Plug>(virgil-prev-note)',                { desc = 'Prev virgil note' })
map('n', ']v', '<Plug>(virgil-next-file)',                { desc = 'Next virgil changeset file' })
map('n', '[v', '<Plug>(virgil-prev-file)',                { desc = 'Prev virgil changeset file' })
```

Two things worth stealing from that, whatever prefix you settle on. `<leader>vR` passes
`HEAD` explicitly, because a bare `:Virgil review` now opens the picker rather than the
working tree. And changeset file cycling sits on `]v` / `[v` rather than the more obvious
`]f` / `[f`, which nvim-treesitter's textobjects already claim for function motions.

Hunk navigation uses diff mode's built-in `]c` / `[c` as-is.

### Review

`:Virgil review origin/main` spreads a changeset into per-file diff tabs. Tabs are created
on visit — a 200-file changeset does not open 200 tabs up front. `<Plug>(virgil-next-file)`
and its pair move between files, `:Virgil files` picks any file directly, and
`:Virgil quit` cleans everything up.

`:Virgil sidebar` puts the whole changeset beside the diff, one row per file:

```
▸ M README.md               +26 -1  31♦
  M lua/virgil/git.lua           +59 -0
  M lua/virgil/changeset.lua      +319 -10
```

`<CR>` opens a row, `q` closes the list. Because a changeset is one tab per file, this is one
window per tab over a **single shared buffer** — what differs between tabs is which row
carries the `▸`, and that is a redraw rather than another window's worth of state. Turning
it off closes it in every tab at once, including the ones you have not visited: a list left
standing in a tab you later walk into reads as the toggle having failed. It is off by
default (`changeset.sidebar = true` opens it with every changeset, `changeset.sidebar_width` sets
the column).

With no arguments it asks which changeset instead: what is uncommitted, **the changesets that
already hold notes**, what this branch adds over the one it tracks, and recent commits
against their parents. The middle one is the point — after an agent leaves notes on a
changeset, that changeset is a list entry rather than a pair of revisions you have to
remember. The last row hands you the command line, where ref completion already works. It
is `vim.ui.select`, so whatever picker you have configured is the one you get.

Where `gh` is installed and the repository has a GitHub remote, one more row opens the
list of pull requests. It is a row you choose rather than one the list waits for: asking
`gh` is a network call, and the other rows should not be held up by it. Picking a pull
request reviews it between its base branch and its head **commit** — a head branch name
only means something in the fork it lives in. If that commit is not in the clone yet,
virgil asks before fetching `pull/N/head`; nothing reaches the network without being
chosen. Neither `gh` nor GitHub is a dependency — without them the row is simply absent.

With two commits the diff is taken from where their histories parted, git's
`base...head` — the same range a forge shows for a pull request, and what the changeset spec
prints. Measuring from the tip of the base branch instead would fold every commit the base
gained since the branch point into the changeset, backwards: files the change never touched,
listed as though it reverted them. A changeset against the working tree keeps the plain
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

A note written inside a changeset records where it came from: the label you typed
(`origin/main..pr-1`), and the two commits that label resolved to. Refs move — `HEAD` moves
with every commit, a branch moves with every fetch — so the label alone cannot name that
changeset again tomorrow, and only the commits can. Two changesets over the same commits are
therefore one changeset however they were spelled, which is what `notes({ changeset = … })`
matches on and what decides whether a note is drawn as this screen's own or as background.
None of it takes part in position calculation; that is the anchor's job alone.

One changeset per instance. Starting a new one tears down the previous changeset's tabs.

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

The socket path comes from `vim.g.virgil_socket`, or defaults to
`$XDG_RUNTIME_DIR/virgil.sock` (`$TMPDIR/virgil-$USER.sock` on macOS). If another instance
already holds that path, this one falls back to `<path>.<pid>`. Socket files left behind by
dead instances are cleaned up automatically. `:Virgil socket` prints the current instance's
path and also puts it on the `+` clipboard.

### The agent's manual

[SKILL.md](SKILL.md) is the file to hand an agent: finding the socket, the quoting rules
that survive `--remote-expr`, and — the part that matters most — what is and isn't worth a
note. It is plain Markdown, so any agent that takes a document as context can read it.

For **Claude Code** it is a skill, and installing it is a symlink. Personal, so it follows
you into every repository:

```sh
mkdir -p ~/.claude/skills/virgil
ln -s "$PWD/SKILL.md" ~/.claude/skills/virgil/SKILL.md
```

Or scoped to one project, and committed with it, so everyone working on the repository
gets it:

```sh
mkdir -p .claude/skills/virgil
ln -s ../../../SKILL.md .claude/skills/virgil/SKILL.md
```

A symlink rather than a copy: the manual then changes when virgil does, and there is one
file to keep honest instead of two. The directory name is what the skill is called, so keep
it `virgil` — the `name` in SKILL.md's frontmatter matches it.

Claude Code reads the `description` from that frontmatter and reaches for the skill on its
own when the work fits — reviewing a diff, pinning a finding, checking what was left
earlier. You can also ask for it by name with `/virgil`. A skill installed mid-session is
picked up by the next one.

Nothing about virgil requires it. The skill is a manual, not an interface: an agent that
has never read it can still call the same `--remote-expr` API, it will just be worse at
deciding what deserves a note.

### Lua API

```lua
local virgil = require('virgil')

virgil.status()                    -- current view's content address, path, cursor, visible note count
virgil.note({ path, line, end_line, summary, rationale, author })
virgil.notes({ path, status, changeset, id })  -- stored anchor + projection into the current view
virgil.update(id, { summary = '…' })
virgil.open(path, { line = 1036, rev = nil })
virgil.remove(id)                  -- delete; nothing else in virgil destroys a note
                                   -- id also accepts a { id1, id2 } list. Omit it for the note under the cursor
virgil.next_note() / virgil.prev_note()
virgil.toggle('all')
virgil.review({ base = 'origin/main', head = nil, paths = { 'internal/' } })
virgil.files()
virgil.export({ format = 'agent-context', changeset = '…', out = '/path.json' })
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
  changeset = {
    layout = 'vertical', -- 'vertical' | 'horizontal'
    highlight = 'syntax',-- 'syntax' | 'filetype' | false
    sidebar = false,     -- open the changed-file list with every changeset
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
| Concurrent changesets | One per instance. A new changeset tears down the previous changeset's tabs on the way in |
| Filetype of the left-hand blob | `filetype` is left unset and only treesitter (or `syntax` if unavailable) is enabled. You get highlighting without a language server attaching to a buffer that has no file. Change it with `changeset.highlight = 'filetype'` |
| Socket lifetime | The first instance takes the canonical path; later ones fall back to `<path>.<pid>`. Socket files from dead instances are cleaned up automatically |
| Telling agent notes from human ones | It goes no further than stamping the name (`author`) dimly in the note's header. Colors aren't split because the distinction that matters is not "who wrote it" but "is this about the change in front of me" — and emphasis versus dimming already carries that |

## Tests

```sh
nvim --clean -l tests/run.lua
```

The suite covers anchoring and projection, persistence across a real second Neovim process,
diff-pair ownership in a changeset, and rendering geometry in narrow windows.

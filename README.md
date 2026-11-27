# herdr-claude-sleeper

Puts long-idle [Claude Code](https://docs.claude.com/en/docs/claude-code) sessions running in
[herdr](https://herdr.dev) panes to sleep, and wakes them on a keypress.

Every Claude Code session is its own process, and an idle one still holds around 350–600 MB of RAM.
With a few dozen sessions left open in herdr tabs, that adds up to many gigabytes for conversations
nobody has touched in days. The conversation itself is already saved on disk (`~/.claude/projects/*.jsonl`),
so the process can be stopped and brought back later with `claude --resume <id>` without losing anything.

claude-sleeper does that automatically:

- Every 15 minutes, a systemd timer checks all claude panes in herdr.
- A session idle for more than 24 hours is stopped and replaced by a placeholder screen in the same pane:

  ```
    💤  Claude is sleeping

        Refactor the invoice exporter
        /home/me/projects/billing

        last active   Mon 19 Oct 17:28  (33d ago)
        asleep since  Sat 21 Nov 20:39
        session       3f2b9c1e-5d4a-4e8b-9f60-1c2d3e4f5a6b

        Press any key to resume · Ctrl+C to leave it asleep
  ```

- Any key resumes the same conversation in the same folder, with the same launch flags.
- Sleeping panes survive a herdr restart or a reboot: herdr brings the placeholder back, not claude.
- The **Sleep Claude in current pane** Herdr action puts an idle Claude session to sleep on demand.

## Requirements

- Linux (reads `/proc`), Python 3, a systemd user session
- herdr 0.9.2 or newer (custom agent resume commands); tested with 0.9.5
- Claude Code, tested with 2.1.330; the herdr Claude integration installed (`herdr integration install claude`)
- `~/.local/bin` on `PATH` in your pane shells

## Install

```sh
./install.sh
```

This symlinks `bin/claude-sleeper` and `bin/claude-wake` into `~/.local/bin`, and links the units in
`systemd/` with `systemctl --user link`. It also links the Herdr plugin from this checkout. Edits
in this repo take effect directly. Re-running it is safe. It does not enable the timer.
Check with a dry run first, then enable it:

```sh
claude-sleeper --dry-run
systemctl --user enable --now claude-sleeper.timer
```

## Sleep the current pane on demand

The Herdr action **Sleep Claude in current pane** skips the 24-hour wait. It only considers the
focused pane and still requires Claude to be idle with no running background jobs.

To bind it to a shortcut, add this to `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+shift+z"
type = "plugin_action"
command = "claude-sleeper.sleep-current"
description = "Sleep Claude in current pane"
```

Choose **reload config** from the Herdr menu, then press your prefix (default `Ctrl+B`) followed by
`Shift+Z` in the Claude pane. You can also invoke the action with
`herdr plugin action invoke claude-sleeper.sleep-current` and see its result with
`herdr plugin log list --plugin claude-sleeper --limit 1`.

## Usage

```
claude-sleeper [--idle-hours N] [--dry-run] [--pane ID | --current] [--session NAME] [-v]
```

| Option | Meaning |
|---|---|
| `--idle-hours N` | Idle threshold, default 24. The timer uses the default. |
| `--dry-run` | Only report what would be put to sleep, and why the rest are kept. |
| `--pane ID` | Only consider this herdr pane (e.g. `wN:p7`). Also sleeps it if it is focused. |
| `--current` | Only consider the pane supplied by Herdr, even if focused. Uses the calling Herdr session. |
| `--session NAME` | Target a named herdr session instead of the default one. |
| `-v` | Also log the sessions that are kept. |
| `--rewake` | Restart the 💤 screen in all sleeping panes (or one with `--pane`) and exit. Use it after updating `claude-wake` (running copies keep the old code) or to repair a pane's herdr registration. |

Examples:

```sh
claude-sleeper --dry-run                        # what would the timer do right now?
claude-sleeper --pane wN:p7 --idle-hours 0      # put one pane to sleep immediately
journalctl --user -u claude-sleeper             # what has the timer done?
claude-wake <session-id>                        # bring back a 💤 screen you left with Ctrl+C
```

## When a session is put to sleep

All of these must hold, otherwise the session is left alone:

- herdr does not report the agent as `working` or `blocked` (waiting on a permission prompt)
- the pane is not focused (unless targeted with `--pane` or `--current`)
- exactly one claude process is in the pane's foreground
- Claude Code's own session file (`~/.claude/sessions/<pid>.json`) says `status: idle`
- no activity for `--idle-hours`, judged by the newer of that file's `statusUpdatedAt` and the last
  timestamped entry in the transcript (the transcript's modification time is useless: Claude Code
  appends untimestamped metadata lines to idle transcripts)
- claude has no background Bash jobs running (child processes started from `~/.claude/shell-snapshots/`)

Right before stopping claude, the session file is checked again. A session that became active in
the meantime is left alone.

## How it works

**Going to sleep** (`claude-sleeper`):

1. Writes the session's details to `~/.local/state/claude-sleeper/<session-id>.json`: folder, title,
   launch flags to keep, pane, timestamps. The folder is readable only by you (mode 0700).
2. Sends claude `SIGTERM`. Claude Code exits cleanly within a second; the transcript is already on disk.
3. Waits for the pane's shell to be back at its prompt.
4. Waits for herdr to let go of the stopped claude. herdr does that only when it sees the pane sitting
   at an idle shell prompt after the agent's process exited, usually within a second. If anything takes
   over the prompt before that, herdr keeps the old claude session attached for good: after a restart it
   would resume claude instead of the 💤 screen, and claude-wake could not register. If herdr has not let
   go after 10 seconds, claude-sleeper runs a 1-second `sleep` under the name `claude` in the pane, so
   herdr sees an agent exit again and lets go. It is a workaround, but the only way found to unstick herdr.
5. Types ` claude-wake <session-id>` into the shell with `herdr pane run` (the leading space keeps it
   out of history if `HISTCONTROL` ignores spaces).

**The 💤 screen** (`claude-wake`):

- Registers itself with herdr as a custom agent (`--source custom:claude-sleeper --agent claude-sleeper`)
  whose resume command is `claude-wake <session-id>`. herdr saves that in its session file, so after a
  herdr restart or reboot it reopens the pane in the same folder and runs `claude-wake` again.
  It registers in two steps, because herdr accepts a resume command only from a source that already
  holds the pane. It re-sends the registration after 3, 10, 30 and 60 seconds and then every 5 minutes,
  which repairs a registration that failed or was cleared.
- On a keypress: unregisters from herdr, deletes the state file, and replaces itself with
  `claude --resume <session-id> <kept flags>` in the original folder. Claude's own herdr integration
  then reports the session, and herdr's built-in Claude resume covers it from then on.
- On Ctrl+C: unregisters and returns to the shell. The state file is kept, so `claude-wake <id>` still works.

**Launch flags.** Flags that shape the session are kept, e.g. `--model`, `--permission-mode`,
`--dangerously-skip-permissions`, `--add-dir`, `--settings`, `--mcp-config`, `--remote-control`.
Flags that choose or create a session are dropped (`--resume`, `--continue`, `--session-id`,
`--fork-session`, `--worktree`), and so is an initial prompt. The log names dropped flags, but not
their values or the prompt.

## What survives a sleep

| Kept | Lost |
|---|---|
| The full conversation | Remote Control connection, unless it is on by default or claude was started with `--remote-control` |
| Folder, launch flags | The session's peer-messaging name |
| A session's place in herdr, across restarts | "Allow for this session" permission approvals (probably) |
| | herdr agent names set with `herdr agent start` |

Sessions with running background jobs are never put to sleep, so no job gets killed.

## Shell prompt hooks

When claude exits, the pane's shell runs its prompt hooks before it shows a prompt. A slow or
interactive hook (for example a direnv `.envrc` that starts an interactive cloud login) holds the
shell up. In that case claude-sleeper marks the session `wake_pending`, and later runs type the wake
command once the shell is free; it gives up after 2 hours and logs how to resume by hand.

Interactive logins in prompt hooks also hold up herdr's resume after a restart, so it is better not to
have them at all: make the login an explicit step you run when a tool says your credentials expired.
For example, if your `.envrc` sources an init script that checks AWS SSO credentials and supports
skipping that check, turn the check off in `.envrc` and run `aws sso login` yourself when needed.

## Files

| Path | What |
|---|---|
| `~/.local/state/claude-sleeper/<session-id>.json` | One per sleeping session; deleted on wake |
| `~/.local/state/claude-sleeper/.lock` | Prevents overlapping runs |
| `~/.config/herdr/session.json` | herdr's saved session; sleeping panes appear as `agent_resume` |

## Known limits

- It depends on two undocumented Claude Code details, which may change between versions: the session
  files in `~/.claude/sessions/` and the transcript format. If they change, sessions are skipped, not
  wrongly put to sleep.
- herdr reports a freshly resumed claude as `unknown` until its next turn; claude-sleeper accepts that
  state and relies on Claude Code's own `idle` status.
- herdr writes its session file a few seconds after a change. A reboot within about 6 seconds of a
  session going to sleep or waking restores the previous state.
- Only panes herdr recognizes as claude are considered. Sessions outside herdr are never touched.
- The rules for when herdr lets a source hold a pane, and when it lets go of an exited agent, are not
  documented. The waiting and the `claude` dummy above are based on observed behavior of herdr 0.9.5.
- Each 💤 screen is a small Python process, about 14 MB, compared with 350–600 MB for an idle claude.
- `~/.local/state/claude-sleeper/nudge/claude` is a symlink to `sleep`, used for the dummy above.

## Uninstall

Wake the sleeping sessions first, or resume them later with `claude --resume <id>` (the IDs are the
file names in `~/.local/state/claude-sleeper/`). Then:

```sh
herdr plugin unlink claude-sleeper
systemctl --user disable --now claude-sleeper.timer
rm ~/.config/systemd/user/claude-sleeper.service ~/.config/systemd/user/claude-sleeper.timer
rm ~/.local/bin/claude-sleeper ~/.local/bin/claude-wake
systemctl --user daemon-reload
```

Remove the `[[keys.command]]` entry for `claude-sleeper.sleep-current` if you added it.

## License

MIT, see [LICENSE](LICENSE).

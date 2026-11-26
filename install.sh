#!/usr/bin/env bash
# Link herdr-claude-sleeper into place. Safe to re-run; edits in this repo take effect directly.
#   ~/.local/bin/claude-sleeper, ~/.local/bin/claude-wake  -> bin/
#   Linux: systemd user units claude-sleeper.{service,timer} -> systemd/  (via `systemctl --user link`)
#   macOS: launchd agent ~/Library/LaunchAgents/local.claude-sleeper.plist, rendered from launchd/
# The timer is NOT enabled; do that yourself once a dry run looks right.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin_dir="$HOME/.local/bin"

mkdir -p "$bin_dir"
for f in claude-sleeper claude-wake; do
	target="$bin_dir/$f"
	if [ -e "$target" ] && [ ! -L "$target" ]; then
		echo "error: $target exists and is not a symlink; move it away first" >&2
		exit 1
	fi
	ln -sfn "$repo/bin/$f" "$target"
	echo "linked $target -> $repo/bin/$f"
done

case ":$PATH:" in
	*":$bin_dir:"*) ;;
	*) echo "warning: $bin_dir is not on PATH; herdr needs to find claude-wake there after a restart" >&2 ;;
esac

install_systemd() {
	local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" u target
	for u in claude-sleeper.service claude-sleeper.timer; do
		target="$unit_dir/$u"
		if [ -e "$target" ] && [ ! -L "$target" ]; then
			echo "error: $target exists and is not a symlink; move it away first" >&2
			exit 1
		fi
		systemctl --user link "$repo/systemd/$u" >/dev/null
		echo "linked $target -> $repo/systemd/$u"
	done
	systemctl --user daemon-reload

	cat <<EOF

Installed. Next steps:
  claude-sleeper --dry-run                             # see what would be put to sleep
  systemctl --user enable --now claude-sleeper.timer   # run it every 15 minutes
  journalctl --user -u claude-sleeper                  # logs
EOF
}

install_launchd() {
	local label=local.claude-sleeper herdr_bin path domain
	local target="$HOME/Library/LaunchAgents/$label.plist"
	# launchd starts agents with a bare PATH; claude-sleeper needs herdr (often in Homebrew's prefix).
	herdr_bin=$(command -v herdr || true)
	if [ -z "$herdr_bin" ]; then
		echo "error: herdr is not on PATH" >&2
		exit 1
	fi
	path="$bin_dir:$(dirname "$herdr_bin"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
	mkdir -p "$(dirname "$target")" "$HOME/Library/Logs"
	# plistlib escapes the values, which sed would not; the file is replaced in one step.
	/usr/bin/python3 -I - "$repo/launchd/claude-sleeper.plist" "$target" "$HOME" "$path" <<'PY'
import os, plistlib, sys
src, dst, home, path = sys.argv[1:]
def fill(v):
    if isinstance(v, str):
        return v.replace("@HOME@", home).replace("@PATH@", path)
    if isinstance(v, list):
        return [fill(x) for x in v]
    if isinstance(v, dict):
        return {k: fill(x) for k, x in v.items()}
    return v
with open(src, "rb") as f:
    plist = fill(plistlib.load(f))
with open(dst + ".tmp", "wb") as f:
    plistlib.dump(plist, f)
os.replace(dst + ".tmp", dst)
PY
	echo "wrote $target"

	domain="gui/$(id -u)"
	if launchctl print "$domain/$label" >/dev/null 2>&1; then
		cat <<EOF

Updated. The agent is loaded; reload it to pick up the new plist (bootout finishes asynchronously):
  launchctl bootout $domain/$label
  launchctl bootstrap $domain $target
EOF
		return
	fi
	cat <<EOF

Installed. The agent is disabled until you enable it. Next steps:
  claude-sleeper --dry-run                       # see what would be put to sleep
  launchctl enable $domain/$label     # enable first, or bootstrap fails with error 5
  launchctl bootstrap $domain $target   # run it every 15 minutes, also after logins
  tail -f ~/Library/Logs/claude-sleeper.log      # logs
EOF
}

case "$(uname -s)" in
	Darwin) install_launchd ;;
	*) install_systemd ;;
esac

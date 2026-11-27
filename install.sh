#!/usr/bin/env bash
# Link herdr-claude-sleeper into place. Safe to re-run; edits in this repo take effect directly.
#   ~/.local/bin/claude-sleeper, ~/.local/bin/claude-wake  -> bin/
#   systemd user units claude-sleeper.{service,timer}       -> systemd/  (via `systemctl --user link`)
#   herdr action claude-sleeper.sleep-current               -> herdr-plugin.toml
# The timer is NOT enabled; do that yourself once a dry run looks right.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin_dir="$HOME/.local/bin"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

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

herdr_bin="${HERDR_BIN_PATH:-herdr}"
"$herdr_bin" plugin link "$repo" >/dev/null
echo "linked herdr action claude-sleeper.sleep-current"

case ":$PATH:" in
	*":$bin_dir:"*) ;;
	*) echo "warning: $bin_dir is not on PATH; herdr needs to find claude-wake there after a restart" >&2 ;;
esac

cat <<EOF

Installed. Next steps:
  claude-sleeper --dry-run                             # see what would be put to sleep
  systemctl --user enable --now claude-sleeper.timer   # run it every 15 minutes
  journalctl --user -u claude-sleeper                  # logs
  herdr plugin action invoke claude-sleeper.sleep-current  # sleep the focused Claude pane
EOF

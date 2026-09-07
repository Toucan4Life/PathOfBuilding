#!/usr/bin/env bash
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
application="$workspace_dir/runtime/Path{space}of{space}Building.exe"
host_runtime_dir="${XDG_RUNTIME_DIR:-}"
host_wayland_display="${WAYLAND_DISPLAY:-}"
state_dir="${POB_RUNTIME_DIR:-${host_runtime_dir:-/tmp}/pob-runtime}"
pid_file="$state_dir/pob-emmy-debug.pid"
log_file="$state_dir/pob-emmy-debug.log"
debugger_port_hex=$(printf '%04X' 9966)
wine_prefix="${XDG_CACHE_HOME:-$HOME/.cache}/pathofbuilding-wine-x11-x64"
export WINEARCH=win64
weston_socket="pob-weston"
weston_pid_file="$state_dir/pob-weston.pid"
weston_log="$state_dir/pob-weston.log"
weston_output_log="$state_dir/pob-weston-output.log"
weston_display_file="$state_dir/pob-weston.display"

debugger_listening() {
	grep -qE ":[0]*$debugger_port_hex[[:space:]]+[^[:space:]]+[[:space:]]+0A" /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

stop_weston() {
	if [[ -f "$weston_pid_file" ]]; then
		read -r weston_pid < "$weston_pid_file"
		if kill -0 "$weston_pid" 2>/dev/null; then
			kill "$weston_pid" 2>/dev/null || true
		fi
	fi
	rm -f "$weston_pid_file" "$weston_display_file" "$state_dir/$weston_socket"
}

if [[ "${1:-}" == "--stop" ]]; then
	if [[ -f "$pid_file" ]]; then
		read -r pob_pid < "$pid_file"
		if kill -0 "$pob_pid" 2>/dev/null; then
			kill "$pob_pid" 2>/dev/null || true
		fi
	fi
	WINEPREFIX="$wine_prefix" wineserver --kill || true
	WINEPREFIX="$wine_prefix" wineserver --wait || true
	rm -f "$pid_file"
	stop_weston
	exit 0
fi

if [[ -z "$host_wayland_display" ]] || [[ -z "$host_runtime_dir" ]] || [[ ! -S "$host_runtime_dir/$host_wayland_display" ]]; then
	printf '%s\n' "The forwarded Wayland display is unavailable." >&2
	exit 1
fi

mkdir -p "$state_dir"
chmod 700 "$state_dir"
ln -sfn "$host_runtime_dir/$host_wayland_display" "$state_dir/$host_wayland_display"
export XDG_RUNTIME_DIR="$state_dir"
export WAYLAND_DISPLAY="$host_wayland_display"

emmy_debugger_dir=""
for extension_dir in "$HOME"/.vscode-server/extensions/tangzx.emmylua-*; do
	if [[ -f "$extension_dir/debugger/emmy/windows/x64/emmy_core.dll" ]]; then
		emmy_debugger_dir="$extension_dir/debugger/emmy/windows/x64"
		break
	fi
done

if [[ -z "$emmy_debugger_dir" ]]; then
	printf '%s\n' "EmmyLua's Windows debugger files were not found." >&2
	exit 1
fi

if [[ -f "$pid_file" ]]; then
	read -r existing_pid < "$pid_file"
	if kill -0 "$existing_pid" 2>/dev/null; then
		pob_pid="$existing_pid"
	else
		rm -f "$pid_file"
	fi
fi

if [[ -f "$weston_pid_file" ]] && [[ -f "$weston_display_file" ]]; then
	read -r weston_pid < "$weston_pid_file"
	read -r x_display < "$weston_display_file"
	if ! kill -0 "$weston_pid" 2>/dev/null || [[ ! -S "/tmp/.X11-unix/X${x_display#:}" ]]; then
		stop_weston
	fi
fi

if [[ ! -f "$weston_display_file" ]]; then
	rm -f "$weston_log" "$weston_output_log" "$state_dir/$weston_socket"
	mkdir -p /tmp/.X11-unix
	chmod 1777 /tmp/.X11-unix
	set -- --backend=wayland-backend.so --display="$WAYLAND_DISPLAY" --socket="$weston_socket" --xwayland --width=1280 --height=800 --idle-time=0 --no-config --log="$weston_log" --use-pixman
	printf '%s\n' "Starting Weston with Pixman software rendering."
	setsid weston "$@" > "$weston_output_log" 2>&1 &
	weston_pid=$!
	printf '%s\n' "$weston_pid" > "$weston_pid_file"

	attempt=0
	x_display=""
	while [[ -z "$x_display" ]] || [[ ! -S "/tmp/.X11-unix/X${x_display#:}" ]]; do
		if ! kill -0 "$weston_pid" 2>/dev/null; then
			printf '%s\n' "Weston exited before Xwayland started." >&2
			stop_weston
			exit 1
		fi
		x_display=$(sed -n 's/.*xserver listening on display \(:[0-9][0-9]*\).*/\1/p' "$weston_log" 2>/dev/null | tail -n 1)
		attempt=$((attempt + 1))
		if [[ "$attempt" -ge 30 ]]; then
			printf '%s\n' "Timed out waiting for Weston's Xwayland display." >&2
			stop_weston
			exit 1
		fi
		sleep 1
	done
	printf '%s\n' "$x_display" > "$weston_display_file"
else
	read -r x_display < "$weston_display_file"
fi

export DISPLAY="$x_display"
export WINEDEBUG=-all
export WINEPREFIX="$wine_prefix"
export WINEDLLOVERRIDES="mscoree,mshtml="
export POB_EMMY_DEBUG=1
export POB_EMMY_DEBUGGER_PATH="$(winepath -w "$emmy_debugger_dir")"

if [[ -z "${pob_pid:-}" ]]; then
	printf '%s\n' "Launching Path of Building with Wine on $DISPLAY..."
	setsid wine "$application" > "$log_file" 2>&1 &
	pob_pid=$!
	printf '%s\n' "$pob_pid" > "$pid_file"
fi

printf '%s\n' "Path of Building is loading..."
elapsed=0
debugger_ready=false
while :; do
	if ! kill -0 "$pob_pid" 2>/dev/null; then
		printf '%s\n' "Path of Building exited before startup completed." >&2
		rm -f "$pid_file"
		exit 1
	fi
	if debugger_listening; then
		if [[ "$debugger_ready" == "false" ]]; then
			printf '%s\n' "EmmyLua debug server is ready."
			debugger_ready=true
		fi
	fi
	if [[ "$debugger_ready" == "true" ]]; then
		break
	fi
	sleep 1
	elapsed=$((elapsed + 1))
	if [[ $((elapsed % 10)) -eq 0 ]]; then
		printf '%s\n' "Path of Building is still loading (${elapsed}s)..."
	fi
	if [[ "$elapsed" -ge 20 ]]; then
		printf '%s\n' "Timed out waiting for EmmyLua." >&2
		exit 1
	fi
done

printf '%s\n' "Path of Building finished loading after ${elapsed}s."
#!/bin/sh
set -eu

zine_exe=$1
site_dir=$2
log_file=$3
port=$4
pid=
temp_dir=

cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    if [ -n "$temp_dir" ]; then
        rm -r "$temp_dir"
    fi
}
trap cleanup EXIT INT TERM

temp_dir=$(mktemp -d)
cp -R "$site_dir/." "$temp_dir"
site_dir=$temp_dir

cd "$site_dir"
"$zine_exe" --host=127.0.0.1 --port="$port" >"$log_file" 2>&1 &
pid=$!

attempt=0
while ! curl --fail --silent --show-error "http://127.0.0.1:$port/" >/dev/null 2>&1; do
    if ! kill -0 "$pid" 2>/dev/null; then
        cat "$log_file" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        cat "$log_file" >&2
        exit 1
    fi
    sleep 0.05
done

curl --fail --silent --show-error "http://127.0.0.1:$port/" |
    grep --quiet '<script defer src="/__zine/zinereload.js"></script>'

marker=zine-live-reload-smoke-marker
printf '\n\n%s\n' "$marker" >>"$site_dir/content/index.smd"

attempt=0
while ! curl --fail --silent --show-error "http://127.0.0.1:$port/" 2>/dev/null |
    grep --quiet "$marker"; do
    if ! kill -0 "$pid" 2>/dev/null; then
        cat "$log_file" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        cat "$log_file" >&2
        exit 1
    fi
    sleep 0.05
done

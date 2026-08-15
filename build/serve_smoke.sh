#!/bin/sh
set -eu

zine_exe=$1
site_dir=$2
log_file=$3
port=$4
pid=

cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

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

#!/bin/sh
set -eu

zig_exe="${HOME}/.zig/0.17.0-dev.1756+613c03321/files/zig"

if [ ! -x "${zig_exe}" ]; then
    echo "required Zig compiler not found or not executable: ${zig_exe}" >&2
    exit 1
fi

exec "${zig_exe}" build "$@"

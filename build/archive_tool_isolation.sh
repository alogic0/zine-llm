#!/bin/sh
set -eu

repo_root=$1
zig_exe=$2
isolated_path=$(mktemp -d)
release_log="${isolated_path}/release.log"

cleanup() {
    if [ -e "${release_log}" ]; then
        rm "${release_log}"
    fi
    if [ -L "${isolated_path}/git" ]; then
        rm "${isolated_path}/git"
    fi
    if [ -L "${isolated_path}/rm" ]; then
        rm "${isolated_path}/rm"
    fi
    rmdir "${isolated_path}"
}
trap cleanup EXIT HUP INT TERM

ln -s "$(command -v git)" "${isolated_path}/git"
ln -s "$(command -v rm)" "${isolated_path}/rm"
cd "${repo_root}"

run_without_archive_tools() {
    PATH="${isolated_path}" "${zig_exe}" build -Dno-git-version "$@"
}

run_without_archive_tools check
run_without_archive_tools test
run_without_archive_tools check-release-targets -Dpreview=true

if run_without_archive_tools release -Dpreview=true >"${release_log}" 2>&1; then
    echo "release unexpectedly succeeded without tar, gtar, zip, or xz" >&2
    exit 1
fi

if ! /usr/bin/grep -Eq 'unable to spawn (tar|zip)|FileNotFound' "${release_log}"; then
    echo "release did not report a missing archive tool" >&2
    /usr/bin/cat "${release_log}" >&2
    exit 1
fi

#!/bin/sh
set -eu

release_dir=$1

set -- "${release_dir}"/*
if [ "$#" -ne 8 ]; then
    echo "expected 8 release archives in ${release_dir}, found $#" >&2
    exit 1
fi

verify_member() {
    archive=$1
    member=$2

    if [ ! -f "${release_dir}/${archive}" ]; then
        echo "missing release archive: ${archive}" >&2
        exit 1
    fi

    case "${archive}" in
        *.zip)
            if ! unzip -Z1 "${release_dir}/${archive}" | grep -Fx "${member}" >/dev/null; then
                echo "${archive} does not contain ${member}" >&2
                exit 1
            fi
            ;;
        *.tar.xz)
            if ! tar -tf "${release_dir}/${archive}" | grep -Fx "${member}" >/dev/null; then
                echo "${archive} does not contain ${member}" >&2
                exit 1
            fi
            ;;
        *)
            echo "unsupported release archive: ${archive}" >&2
            exit 1
            ;;
    esac
}

verify_member aarch64-freebsd.15.0.tar.xz zine
verify_member aarch64-linux-musl.tar.xz zine
verify_member aarch64-macos.zip zine
verify_member aarch64-windows.zip zine.exe
verify_member x86_64-freebsd.15.0.tar.xz zine
verify_member x86_64-linux-musl.tar.xz zine
verify_member x86_64-macos.zip zine
verify_member x86_64-windows.zip zine.exe

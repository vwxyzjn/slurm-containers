#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CoreWeave, Inc.
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-PackageName: slurm-containers
set -euo pipefail
# Run as root in a disposable cgroup-v2 VM/container with a writable cgroup mount.
source_dir=${1:?usage: kernel.sh /path/to/patched-slurm-source}
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
binary=$(mktemp)
cgroup_dir=$(mktemp -d /sys/fs/cgroup/slurm-delegation-test.XXXXXX)
cleanup() {
  if [[ -e "$cgroup_dir/cgroup.kill" ]]; then
    echo 1 > "$cgroup_dir/cgroup.kill" || true
  fi
  find "$cgroup_dir" -depth -type d -exec rmdir {} \; 2>/dev/null || true
  rm -f "$binary"
}
trap cleanup EXIT
cc -std=gnu11 -Wall -Wextra -Werror -O2 \
  -I "$source_dir/src/plugins/cgroup/v2" "$test_dir/kernel.c" -o "$binary"
"$binary" "$cgroup_dir"

<!--
SPDX-FileCopyrightText: 2026 CoreWeave, Inc.
SPDX-License-Identifier: GPL-2.0-or-later
SPDX-PackageName: slurm-containers
-->

# Task memory delegation

Patch `0025-task-memory-delegation.patch` lets an opted-in Slurm task create
memory-limited child cgroups. This is useful for a task that hosts several
services or query workers and needs to contain one worker's memory usage.
It does not set a memory limit automatically or install a container runtime.

## Enablement

Install matching patched `slurmd`, `slurmstepd`, libraries, and plugins, then
restart `slurmd` with this additional `cgroup.conf` setting:

```ini
CgroupPlugin=cgroup/v2
EnableTaskDelegation=yes
```

The setting defaults to `no`. SUNK already accepts arbitrary entries under
`slurmConfig.cgroupConfig`; an operator change is not required:

```yaml
slurmConfig:
  cgroupConfig:
    CgroupPlugin: cgroup/v2
    EnableTaskDelegation: true
```

Only enable the setting after all affected images support it. Older binaries
reject the unknown configuration key. The slurmd-to-stepd configuration payload
also changes, so do not mix patched and unpatched executables or shared libraries
within a node. Existing steps should finish before reverting the runtime.

Opt in through the environment exported to the step:

```sh
SLURM_CGROUP_DELEGATE=memory srun --oom-kill-step=0 your-launcher
```

On patched cgroup/v2 nodes, an invalid value or a request when the administrator
has disabled delegation fails launch. Unpatched nodes do not recognize the
environment variable: launchers must check that delegation actually exists and
fail if it does not. Select a partition containing only patched nodes for the
initial rollout.

Keep the existing `task/cgroup` and `proctrack/cgroup` plugins and memory
controller available. Normal tasks retain their existing cgroup layout.
Delegation does not change resource selection, memory scheduling, or ancestor
limits. It only grants control over descendants of one Slurm task.

## Hierarchy and permissions

```text
task_N/                    root-owned Slurm limits and hierarchical accounting
  delegated/               job-owned directory and delegation interfaces
    main/                  initial application process
    worker-1/              application-created memory-limited worker
    worker-2/
```

Slurm creates this layout before releasing the application and directs repeated
task-placement calls to `delegated/main`. Only the memory controller is exposed
below `task_N`. CPU and device restrictions remain inherited from Slurm.

The job UID owns the delegated directories and `cgroup.procs`, `cgroup.threads`,
and `cgroup.subtree_control`. Slurm retains ownership of the delegated root's
limit files and all task/step/job ancestors. Linux checks permission at the
common ancestor when moving processes, preventing migration between task trees,
including trees owned by the same UID. The root-owned task permits at most 258
descendants and a depth of 6. Slurm recursively enumerates task descendants for
PID tracking and removes abandoned child groups during teardown.

This is cooperative resource management within a Unix identity. A process that
can change its own child cgroup's limit can remove that limit. Use a separate
identity or sandbox for mutually untrusted code.

## Starting a capped worker

For a normal host-side task with `/sys/fs/cgroup` mounted, this minimal example
starts a command with a 64 GiB RAM limit and no swap:

```bash
set -euo pipefail
relative=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)
case "$relative" in
  */delegated/main) ;;
  *) echo 'Task memory delegation is unavailable' >&2; exit 1 ;;
esac
delegated="/sys/fs/cgroup${relative%/main}"
worker=$(mktemp -d "$delegated/worker.XXXXXX")
trap 'rmdir "$worker" 2>/dev/null || true' EXIT
echo 68719476736 > "$worker/memory.max"
echo 0 > "$worker/memory.swap.max"
echo 1 > "$worker/memory.oom.group"
(
  echo "$BASHPID" > "$worker/cgroup.procs"
  exec your-worker-command
)
```

Set the limit and move a new process before it allocates memory. Existing memory
charges do not follow a migrated process. Repeat the operation on every worker
restart, and leave headroom above the application's internal memory budget.
Keep intermediate cgroups empty of processes before enabling controllers.

An OOM kill loses the worker's in-flight work. Applications must report this as
an infrastructure failure and decide whether to retry. With `OOMKillStep` enabled,
Slurm can kill the entire step in response to a descendant OOM; use
`--oom-kill-step=0` when sibling survival is required. Slurm still observes and
reports descendant OOM events, which can affect the final step status.

Containerized tasks additionally need a writable view of the delegated subtree
and compatible UID mappings. The patch does not change Pyxis/Enroot mounts or
user namespaces. Verify the actual launch environment before enabling callers;
the host-side example intentionally fails when that view is unavailable.

## Validation

Apply the normal patch stack to the Slurm source version used by the image.
Build Slurm, including the cgroup/v2 plugin, and run the kernel test as root in
a disposable Linux VM or private-cgroup-namespace container with a writable
cgroup-v2 mount:

```sh
./tests/task-delegation/kernel.sh /path/to/patched-slurm-source
```

The container's supervising processes must be in a leaf and the memory controller
enabled at its namespace root before running the test. Do not run the test on a
production node. It creates an isolated test subtree, deliberately triggers a
32 MiB OOM, and removes the subtree on exit.

The test exercises actual kernel behavior: permissions, cross-task migration
with the same UID, child OOM containment, hierarchical OOM reporting, depth/count
bounds, nested PID discovery, SIGTERM delivery, and recursive teardown. It is
not a replacement for a scheduler canary. Before rollout, test ordinary and
opted-in jobs, rejected opt-ins, job cancellation/requeue, accounting, Pyxis
visibility, worker restarts, and representative application performance using
the exact deployment image.

The scheduler integration test starts a single-node Slurm cluster in a disposable
container. It requires patched Slurm binaries on `PATH`, Munge, and Python 3:

```sh
docker run --rm --hostname delegation-test --privileged --cgroupns=private \
  --entrypoint /bin/bash -e SLURM_DELEGATION_TEST_DISPOSABLE=yes \
  -v "$PWD/tests/task-delegation/slurm.sh:/test.sh:ro" \
  PATCHED_SLURM_IMAGE /test.sh
```

It checks ordinary launch, a child OOM with a surviving task, nested PID inventory,
cancellation, abandoned-group cleanup, invalid opt-ins, and opt-ins while the
administrator setting is disabled. It overwrites the container's Slurm
configuration, so it must only run in a disposable container with a private
cgroup namespace.

#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CoreWeave, Inc.
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-PackageName: slurm-containers
# Destructive to the disposable container's Slurm configuration; never run on a node.
set -euo pipefail
: "${SLURM_DELEGATION_TEST_DISPOSABLE:?Run only in a disposable test container}"
trap 'rc=$?; if ((rc)); then tail -60 /tmp/slurmd.log /tmp/slurmctld.log /tmp/daemon.stdout /tmp/controller.stdout 2>/dev/null || true; fi' EXIT
mount -o remount,rw /sys/fs/cgroup
mkdir /sys/fs/cgroup/runner
while read -r pid; do echo "$pid" > /sys/fs/cgroup/runner/cgroup.procs; done < /sys/fs/cgroup/cgroup.procs
echo '+memory +cpu +cpuset' > /sys/fs/cgroup/cgroup.subtree_control
mkdir -p /etc/slurm /var/spool/slurmctld /var/spool/slurmd /run/munge /var/log/munge /etc/munge
chown -R munge:munge /run/munge /var/log/munge /etc/munge
if [[ ! -f /etc/munge/munge.key ]]; then
  head -c 1024 /dev/urandom > /etc/munge/munge.key
  chown munge:munge /etc/munge/munge.key
  chmod 600 /etc/munge/munge.key
fi
runuser -u munge -- munged --force
cat > /etc/slurm/slurm.conf <<'CONF'
ClusterName=delegation-test
SlurmctldHost=delegation-test
SlurmUser=root
SlurmdUser=root
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/tmp/slurmctld.log
SlurmdLogFile=/tmp/slurmd.log
SlurmdParameters=config_overrides
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup,task/affinity
JobAcctGatherType=jobacct_gather/cgroup
SelectType=select/cons_tres
SelectTypeParameters=CR_Core
ReturnToService=2
MpiDefault=none
CONF
slurmd -C | head -1 >> /etc/slurm/slurm.conf
echo 'PartitionName=cpu Nodes=delegation-test Default=YES MaxTime=INFINITE State=UP' >> /etc/slurm/slurm.conf
cat > /etc/slurm/cgroup.conf <<'CONF'
CgroupPlugin=cgroup/v2
IgnoreSystemd=yes
ConstrainCores=yes
ConstrainRAMSpace=yes
EnableTaskDelegation=yes
CONF
slurmctld -D > /tmp/controller.stdout 2>&1 &
slurmd -D > /tmp/daemon.stdout 2>&1 &
slurmd_pid=$!
for _attempt in {1..60}; do
 if sinfo -h -o '%T' | grep -q '^idle$'; then break; fi
 sleep 1
done
sinfo
cd /tmp
runuser -u nobody -- srun --immediate=5 --nodes=1 --ntasks=1 sh -c 'cat /proc/self/cgroup' > /tmp/ordinary.out
cat /tmp/ordinary.out
if grep -q '/delegated/' /tmp/ordinary.out; then exit 1; fi
# Expand variables inside the launched task, not in the test supervisor.
# shellcheck disable=SC2016
runuser -u nobody -- env SLURM_CGROUP_DELEGATE=memory srun --immediate=5 --nodes=1 --ntasks=1 --oom-kill-step=0 bash -c '
set -euo pipefail
relative=$(awk -F: '\''$1 == "0" { print $3 }'\'' /proc/self/cgroup)
case "$relative" in */delegated/main) ;; *) exit 10;; esac
base=/sys/fs/cgroup${relative%/main}
mkdir "$base/worker"
echo 33554432 > "$base/worker/memory.max"
echo 0 > "$base/worker/memory.swap.max"
echo 1 > "$base/worker/memory.oom.group"
(echo "$BASHPID" > "$base/worker/cgroup.procs"; exec python3 -c "x=bytearray(128*1024*1024)") &
worker=$!
status=0
wait "$worker" || status=$?
test "$status" = 137
mkdir "$base/abandoned"
echo "PASS: Slurm task survived worker OOM at $relative"
' > /tmp/delegated.out 2>&1 || true
grep -q 'PASS: Slurm task survived worker OOM' /tmp/delegated.out
cat /tmp/delegated.out
for _attempt in {1..60}; do
  if ! find /sys/fs/cgroup -type d -name delegated | grep -q .; then break; fi
  sleep 1
done
if find /sys/fs/cgroup -type d -name delegated | grep -q .; then
 echo 'FAIL: delegated cgroup leaked'; exit 1
fi
if runuser -u nobody -- env SLURM_CGROUP_DELEGATE=invalid srun --immediate=5 --nodes=1 --ntasks=1 true > /tmp/rejected.out 2>&1; then
 echo 'FAIL: invalid opt-in accepted'; exit 1
fi
cat /tmp/rejected.out
# A live nested process must appear in Slurm's PID inventory and be cancelled.
# shellcheck disable=SC2016
runuser -u nobody -- env SLURM_CGROUP_DELEGATE=memory srun --immediate=5 --nodes=1 --ntasks=1 bash -c '
set -euo pipefail
relative=$(awk -F: '\''$1 == "0" { print $3 }'\'' /proc/self/cgroup)
base=/sys/fs/cgroup${relative%/main}
mkdir "$base/cancel"
echo "$BASHPID" > "$base/cancel/cgroup.procs"
echo "$SLURM_JOB_ID $BASHPID" > /tmp/cancel-ready
exec sleep 300
' > /tmp/cancel.out 2>&1 &
srun_pid=$!
for _attempt in {1..60}; do
  [[ -s /tmp/cancel-ready ]] && break
  sleep 1
done
read -r cancel_job cancel_pid < /tmp/cancel-ready
scontrol listpids "$cancel_job" > /tmp/pids.out
grep -q "^${cancel_pid}[[:space:]]" /tmp/pids.out
scancel "$cancel_job"
wait "$srun_pid" && { echo 'FAIL: cancelled job succeeded'; exit 1; }
for _attempt in {1..60}; do
  if ! find /sys/fs/cgroup -type d -name delegated | grep -q .; then break; fi
  sleep 1
done
if find /sys/fs/cgroup -type d -name delegated | grep -q .; then
  echo 'FAIL: cancellation leaked a delegated cgroup'; exit 1
fi
# Restart the daemon with delegation disabled and check both launch paths.
kill "$slurmd_pid"
wait "$slurmd_pid" || true
sed -i 's/EnableTaskDelegation=yes/EnableTaskDelegation=no/' /etc/slurm/cgroup.conf
slurmd -D > /tmp/daemon.stdout 2>&1 &
for _attempt in {1..60}; do
  if scontrol show slurmd >/dev/null 2>&1; then break; fi
  sleep 1
done
if runuser -u nobody -- env SLURM_CGROUP_DELEGATE=memory srun --immediate=5 --nodes=1 --ntasks=1 true > /tmp/disabled.out 2>&1; then
  echo 'FAIL: disabled delegation accepted'; exit 1
fi
grep -q 'requires EnableTaskDelegation=yes' /tmp/slurmd.log
runuser -u nobody -- srun --immediate=5 --nodes=1 --ntasks=1 true
echo 'PASS: Slurm ordinary launch, delegation, OOM isolation, nested PID inventory, cancellation, cleanup and rejected opt-ins'

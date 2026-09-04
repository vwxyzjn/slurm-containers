# Concurrent Preemption For Array Tasks

Patch `0037-array-launch-transactions.patch` is a review candidate on top of
the complete `joblaunch9` stack through `0036`. It is not deployed. The existing
node-ownership fence, minimal victim selection, victim grace handling, and
hetjob launch barrier remain in place.

## The Problem

An array is many independent tasks, but Slurm initially stores its pending
tasks in one shared job record. The previous transaction code attached one
resource plan to that record. While that plan waited for preemption, the next
task could not prepare its own plan.

```text
Shared pending record: tasks A, B, C, ...
                          |
                          +-- one plan, for A

Time ---------------------------------------------------->
A: [ grace ][ cleanup ][ running.........................]
B:                     [ grace ][ cleanup ][ running.....]
```

The serialization was not required by Slurm or the 300-second grace policy.
Upstream's array loop supports multiple preemption attempts. Our persistent,
job-ID-keyed plan accidentally constrained that loop to the first task's nodes.
On AWS6, task `2322755_68` started at `2026-09-04T16:16:24.955Z`, and the next
transaction opened at `16:16:24.982Z`. The prior task did not have to finish,
but it did have to acquire its allocation.

## The New Shape

Split out an individual pending task **before** committing its plan or signaling
victims. Use Slurm's existing `job_array_pre_sched()` and `job_array_split()`
machinery instead of inventing another kind of job identity.

```text
Shared pending record: remaining tasks D, E, F, ...

Task A record          Task B record          Task C record
    |                      |                      |
 unique job ID          unique job ID          unique job ID
    |                      |                      |
 own node plan          own node plan          own node plan
    |                      |                      |
 grace + cleanup        grace + cleanup        grace + cleanup
    |                      |                      |
   start                  start                  start
```

The scheduler can prepare further tasks in subsequent backfill cycles while
earlier tasks are still waiting. This is bounded pipelining, not a promise that
every task gets a plan in one cycle or that all tasks start simultaneously.
After opening a waiting task's plan, that queue attempt ends instead of
re-entering the upstream `next_task` loop with the previous task's plan.

The task's new ID owns its node fence, victim list, status, timeout, and failure
budget. The remainder of the array does not inherit that task's active flag,
grace-start bookkeeping, cooldown, or exhausted retry budget. Any main-scheduler
handoff for the old shared record is completed before the identity changes.
Other queued partition/QOS alternatives still referring to the old record are
redirected to the remaining array record.

An ordinary non-array job still owns one plan. A hetjob still owns one
coordinated group plan. This patch does not split hetjob components into
independent preemption owners.

## Two Limits, Not One

`--array=0-99%10` caps running tasks at ten. The scheduler must also avoid
preempting victims for more tasks than there are launch slots available.

```text
Array limit: 10

Running:          6
Preparing:        3  (committed plans, including cleanup)
Available slots:  1
```

The shared record counts durable preparation slots independently of Slurm's
temporary `pend_run_tasks` counter. That temporary counter is reset during
queue building and must not invalidate an already committed owner.

- A new plan consumes a slot before victim signals.
- Starting a task converts its preparation slot into a running task under the
  controller's job write lock.
- Cancellation, job-record purge, transaction teardown, or completed failure
  cleanup releases the preparation slot exactly once.
- Failure cleanup retains the slot while the old plan still owns resources.
  Cooldown and permanently blocked tasks no longer own a preparation slot.
- All callers of `job_array_start_test()`, including the main scheduler, count
  reserved slots when considering an uncommitted task. Such tasks cannot take
  the concurrency budget promised to committed owners, even on idle nodes.
- An existing owner checks the running-task limit without counting pending
  reservations against itself. Lowering `%N` while plans exist stops new plans;
  existing owners can drain as running slots become available instead of
  mutually blocking forever. Existing running tasks are not killed.

A second limit bounds outstanding plans per array:

```text
SchedulerParameters=...,bf_max_job_array_launch=20
```

The default is 20; accepted values are 0 through 1000. Use 2 for an initial
canary. A value of 1 serializes preparation per array while retaining the
per-task ownership and slot-accounting fixes. Zero prevents **new array
preemption transactions**, but does not disable idle-resource starts, ordinary
non-array preemption, or retries of existing plans. Lowering this cap does not
discard plans already committed. `ArrayPreemptionLimit` means this cap is full;
`JobArrayTaskLimit` means the array's running/preparing budget is full.

This setting is separate from upstream `bf_max_job_array_resv`, which limits
backfill look-ahead. Raising the latter alone did not fix the old bottleneck.
Existing backfill depth, time, priority, and per-user limits still apply.

## What Does Not Change

- The committed nodes are fenced before any victim signal, and plans cannot
  overlap node ownership. Fencing remains node-granular even for a one-GPU task
  on a shared node; this patch does not introduce GPU-level reservations.
- The victim list is the sufficient prefix selected by the existing simulator,
  not every job on the selected nodes.
- Victims using the `preemptible` QOS retain their configured 300-second grace.
  Victims that voluntarily release resources early allow an earlier start;
  cleanup can delay allocation beyond 300 seconds.
- A previously signaled multi-node victim is not signaled again by another
  task's disjoint plan.
- Each task retains bounded failure cleanup, cooldown, and replanning. Failure
  of one prepared task no longer permanently blocks the shared array record.
- `SchedNodeList` and `SystemComment` describe each prepared task's own plan.
  Use `squeue -r -j ARRAY_ID` and `scontrol show job ARRAY_ID_TASK_ID` to inspect
  individual tasks. The unsplit remainder has no single committed node plan.

## Validation And Rollout Gates

### Completed On 2026-09-04

- The 29 canonical patches plus candidate `0037` (30 total) apply cleanly to
  pristine Slurm `25.05.3`. Every modified file matches the edited source
  byte-for-byte.
- A Linux/amd64 Ubuntu 22.04 build completes for the full Slurm tree, including
  the controller and plugins. The final changed translation units also compile
  under the regression harness's strict pointer, implicit-declaration, and
  unused-variable checks with `NDEBUG` enabled.
- All five C regression groups pass, including a shared multi-node victim
  referenced by disjoint plans: it receives one preemption initiation, and
  canceling one owner leaves the other owner's plan intact.
- A disposable local controller with four real `slurmd` processes exercises
  the actual scheduling loop and array-record split, not the unit-test mock.
  It uses CPU-only nodes, `preempt/partition_prio`, a 300-second low-partition
  grace period, four victims that ignore `SIGTERM`, and an array with `%2` and
  `bf_max_job_array_launch=2`. No production cluster is involved.

Observed UTC timeline:

| Time | Event |
| --- | --- |
| `16:37:01.593` | Task `9_0` commits node1 and starts preemption of one victim. |
| `16:37:02.594` | Task `9_1` commits node2 and starts preemption of one victim, while `9_0` is still waiting. |
| During grace | Both owners show `Preempting` with separate `SchedNodeList` values. Tasks `9_2` through `9_4` show `JobArrayTaskLimit`; the two unrelated victims on node3 and node4 keep running. |
| `16:42:10.004` | Slurm enforces victim requeue after approximately 308 and 307 seconds, respectively. Neither victim is forcibly terminated before grace expires. |
| `16:42:39.794–795` | Victim cleanup completes. |
| `16:42:39.970–972` | Both owners start on their original nodes, two milliseconds apart; both transactions release. The remaining array tasks stay limited by `%2`. |

The roughly 338-second allocation wait consists of overlapping grace periods,
controller timer granularity, and cleanup. It is not two sequential grace
periods. This validates CPU/partition-priority behavior, not production
QOS/GPU cleanup or large-array controller latency; the rollout gates below
remain necessary.

Patch SHA-256:

```text
aef81b0aaa997ca592fafd20b007880c314c321de1f41d02ce98edabbd08b4d5
```

### Repeatable Unit Coverage

The patch adds a Linux C regression harness beside the upstream backfill tests:

```bash
# From a configured and built Slurm source tree with the full stack applied:
bash testsuite/slurm_unit/backfill/test_launch_transactions.sh
```

It compiles the actual patched `job_mgr.c`, `node_scheduler.c`, and backfill
functions, including the real slot-accounting helpers and node fence. It uses
`NDEBUG` with checks that remain active. Job lookup, array-record splitting,
time, and victim signaling are mocked: this is not a substitute for exercising
the real scheduler queue, Slurm job hash tables, or physical GPU cleanup.

Covered cases include concurrent independent plans; node ownership before
signals; no repeat victim signal at 299 or 301 seconds; completion cleanup;
per-array plan caps; `%N` slot accounting; the last shared-array task;
lowering `%N`; cancellation; slot conversion on start; cleanup and bounded
retry isolation; teardown; and ordinary-job/hetjob routing.

### Required Before Rollout

Before rollout, test the complete image on an isolated cluster:

1. Fill at least four eligible nodes with victims that remain alive during
   grace. Submit a one-node array with `%2` and confirm two disjoint plans exist
   before either owner starts. The third task must not start or preempt yet.
2. Verify no forced victim termination occurs before the configured 300
   seconds. Verify both owners acquire their original nodes after cleanup.
3. Repeat with early-exiting victims and with real one-GPU shared-node jobs;
   count actual victims and verify unrelated colocated jobs keep running.
4. Cancel one owner during grace; verify its slot and fence clear without
   dropping the other owner's plan. Cancellation still does not undo signals
   already sent to victims.
5. Exercise an individually held or requeued array task, the final array task,
   a node drain, cleanup failure, `%N` reduction, and controller reconfigure or
   restart. Check for leaked slots and cross-task status/retry inheritance.
6. Repeat the existing ordinary-job and hetjob regression matrix, and watch
   controller RPC latency during a large array wave.

**Rebuild the controller and its Slurm plugins together.** This patch changes
the internal `job_record_t` layout and controller-side array helpers. Do not
use the old backfill-plugin-only overlay build procedure. There is no wire
protocol change, but old controller plugins must not be mixed with the new
controller binary.

Keep preparation counters in memory, like the node-ownership registry. They
are not serialized; restart loses the plans and recomputes scheduling. Human
review, human GitOps merge, and human Argo sync remain mandatory. This patch
does not authorize a rollout or changes to compute-node images.

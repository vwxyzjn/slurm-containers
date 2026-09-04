# Slurm Patches

The next controller candidate adds `0037-array-launch-transactions.patch` to
the `joblaunch9` stack. It gives array tasks independent, bounded preemption
plans and owner-aware concurrency slots. See [ARRAY_PREEMPTION.md](ARRAY_PREEMPTION.md)
for the design, validation, and rollout limits. Rebuild the controller and all
Slurm plugins together; this is not a backfill-plugin-only update.

This file explains the patches in this directory, why they exist, and reasons why they are not
likely to be added to the upstream code.

As noted in the top-level slurm-containers README, the patches are released
under the same terms as the parent source files of SLURM, and the specific
licenses of each of those files should be consulted by users who require
validation, as they may be GPL-2.0-or-later, Apache 2.0 or various BSD-style
licenses.

## Table of Contents

- [Slurm Patches](#slurm-patches)
  - [Table of Contents](#table-of-contents)
  - [0001-max-server-threads](#0001-max-server-threads)
  - [0002-agent-thread](#0002-agent-thread)
  - [0003-revert-no-dynamic-sort](#0003-revert-no-dynamic-sort)
  - [0004-rest-get-node-default-flags](#0004-rest-get-node-default-flags)
  - [0005-allow-persistent-none](#0005-allow-persistent-none)
  - [0006-allow-all-topology](#0006-allow-all-topology)
  - [0007-cgroup-v2](#0007-cgroup-v2)
  - [0008-job-skip-ids](#0008-job-skip-ids)
  - [0014-25.05-fix-xcpuinfo-core-count.patch](#0014-2505-fix-xcpuinfo-core-countpatch)
  - [0015-remove-gres-core-range-matches-sock.patch](#0015-remove-gres-core-range-matches-sockpatch)
  - [0016-scontrol-dashboards](#0016-scontrol-dashboards)
  - [0019-empty-pids-retry](#0019-empty-pids-retry)
  - [0020-empty-topology](#0020-empty-topology)
  - [0021-revert-remove-cg-limits.patch](#0021-revert-remove-cg-limitspatch)
  - [0022-move-persist-conn-shutdown.patch](#0022-move-persist-conn-shutdownpatch)
  - [0023-fail-bad-constraints.patch](#0023-fail-bad-constraintspatch)
  - [0024-hetjob-sticky-preempt.patch](#0024-hetjob-sticky-preemptpatch)
  - [0025-hetjob-pinned-plan.patch](#0025-hetjob-pinned-planpatch)
  - [0026-hetjob-planned-preemptions.patch](#0026-hetjob-planned-preemptionspatch)
  - [0027-hetjob-launch-transaction-clean.patch](#0027-hetjob-launch-transaction-cleanpatch)
  - [0028-job-launch-transaction-clean.patch](#0028-job-launch-transaction-cleanpatch)
  - [0029-hetjob-launch-all-components.patch](#0029-hetjob-launch-all-componentspatch)
  - [0030-job-launch-preempt-before-start.patch](#0030-job-launch-preempt-before-startpatch)
  - [0031-launch-transaction-status.patch](#0031-launch-transaction-statuspatch)
  - [0032-launch-transaction-node-ownership.patch](#0032-launch-transaction-node-ownershippatch)
  - [0033-launch-transaction-reliability.patch](#0033-launch-transaction-reliabilitypatch)
  - [0034-launch-transaction-bounded-replan.patch](#0034-launch-transaction-bounded-replanpatch)
  - [0035-launch-transaction-minimal-victims.patch](#0035-launch-transaction-minimal-victimspatch)
  - [0036-launch-transaction-visibility.patch](#0036-launch-transaction-visibilitypatch)

### 0001-max-server-threads

This patch increases the maximum number of server threads allowed in `slurmctld`. The value here is
roughly equivalent to the maximum number of nodes in a cluster. This increase prevents artificial
bottlenecks on threads when handling communication for nodes. Initially, dynamic nodes in Slurm did
not support fan-out, so all communications were directly from the controller. When handling large
jobs with many start/end operations, the messages could get stuck waiting for threads. This
bottleneck artificially limits and, in many cases, times out communications with the controller.
CoreWeave observed this bottleneck as cluster sizes reached 500 to 1000 nodes. We have observed that
setting the maximum number of server threads near or greater than the maximum number of nodes
prevents this bottleneck.

When we discussed this with the upstream maintainers, the communication we received indicated that
we could test this setting, but the upstream code has no plan to adjust the value. The upstream
solution is to use fan-out. Although fan-out is now available with dynamic nodes, we have
experienced issues with this option. We prefer to increase the maximum number of server threads as a
solution.

### 0002-agent-thread

This patch also increases the maximum threads available to process messages, with a slightly
different effect than the `0001-max-server-threads` patch. This patch addresses the same
bottlenecking behavior and communication timeouts we observed in large clusters. Like the prior
patch, the upstream maintainers are not considering changing this value, and prefer reducing the
controller load with fan-out.

### 0003-revert-no-dynamic-sort

This patch was originally applied to the upstream code in response to
[a bug we filed](https://support.schedmd.com/show_bug.cgi?id=16295), but was later reverted because
the patch also caused issues in other cases.

The sort order of nodes impacts how jobs are scheduled, and the way nodes are named reflects the
general network topology. If the nodes are not sorted, the scheduling can be non-optimal. We have
enabled the topology file to help optimize scheduling, but that has some other side effects, and not
all users are familiar with using topology files.

Since backing out the patch, the upstream project has not provided us with any further updates. If
this is fixed in the upstream code, then this patch will no longer be required.

### 0004-rest-get-node-default-flags

This patch is a workaround for a bug in `slurmctld` that causes the controller to crash with a
memory access error. We have
[a bug tracking this issue](https://support.schedmd.com/show_bug.cgi?id=20543) in the upstream
project.

Initially, we made a patch to `slurmctld`. That patch was invasive, so we elected to handle the
issue differently by not requesting details when accessing node information with `slurmrestd`.
However, we encountered [another bug](https://support.schedmd.com/show_bug.cgi?id=20559) with
`slurmrestd` with that approach.

This patch is a fast way to fix the second bug that works for our use case because we never need to
set the `SHOW_DETAILS` flag on the request. If we stop using the REST API for our integration with
SUNK or the upstream project corrects one of the two existing bugs, then this patch is no longer
necessary.

### 0005-allow-persistent-none

This patch allows `slurmctld` to make persistent connections, except for the special cases of
federation and accounting. Those two cases have behaviors that aren't desirable for a generic,
persistent RPC connection.

This patch treats the initialization of `PERSIST_TYPE_NONE` persistent connections the same as
`PERSIST_TYPE_ACCT_UPDATE`. This behavior allows us to use persistent RPC connections with our
client library instead of making new connections for each message and should be more efficient.
We have not submitted this to the upstream project because their current stance is not to address
the various other bugs we have reported and because this is considered a feature request, not a bug.

### 0006-allow-all-topology

This patch allows for both `topology/tree` and `topology/block` configuration to be present in the
topology configuration file `topology.conf`. This is done by updating the flags used in parsing the
file to ignore lines that do not match the expected contents for each of the topology plugins.
Without this patch when the topology plugins encounter a line that does not match their expected
format, `slurmctld` will exit with error
`something wrong with opening/reading /etc/slurm/topology.conf: Invalid argument`.

This is to allow generating information for both topology plugins in the `topology.conf` file by
SUNK without being conditional on which plugin is currently active. Validation that the expected
topology is loaded can still be done by `scontrol show topo`. Since the topology is generated it is
unlikely to have the type of formatting errors on lines that the prior behavior would catch.
Additionally, having a functional `slurmctld` even with "degradation" with respect to topology is
preferred over it being non-functional and taking the cluster down.

### 0007-cgroup-v2

This patch bypasses an issue with the Slurm cgroup/v2 plugin in which processes are incorrectly
reassigned to a new cgroup multiple times. When `slurmd` starts, the plugin creates a subdirectory
and moves the `slurmd` process into it to avoid interfering with other processes. This is part of an
effort to avoid issues when using a false cgroup root, but may occur more than once, leading to
`slurmd` failures. This modification ensures that this only occurs when `slurmd` starts for the
first time.

### 0008-job-skip-ids

This patch allows the user to enter job ids in an environment variable `SLURM_JOB_SKIP_IDS` on the
slurm chart. The ids provided will skip job processing from Slurm. This is useful when a job id
becomes corrupted. When Slurm has a corrupted job id, it will fail to process the job and lock up.
This will cause no new jobs to be able to processed or started. Skipping these jobs breaks the loop
and allows Slurm to continue to process jobs.

If upstream was to correct the root cause of why job ids become corrupted or handle corrupted job
ids gracefully then this patch would no longer be required.

### 0014-25.05-fix-xcpuinfo-core-count.patch

This patch fixes a bug in the `xcpuinfo.xcpuinfo_get_cpuspec` function that incorrectly calculates the
number of cores on the machine - it misses the inclusion of sockets.
ref: [SchedMD 22797](https://support.schedmd.com/show_bug.cgi?id=22797)

### 0015-remove-gres-core-range-matches-sock.patch

This is reverting a change that was first introduced in the following commit:
[Slurm Commit](https://github.com/SchedMD/slurm/commit/b886b6e82fc5194e057488027a29d201c10846bb)

When we have the previous 0011-25.05-container-fixes patch applied, the newly constrained node will never
be allowed to join the cluster because the gres core range will never match the socket count.

### 0016-scontrol-dashboards

This patch adds node and job Grafana dashboard URLs to the outputs of `scontrol show node` and
`scontrol show job`. It also prints the job dashboard URL in interactive srun sessions, slurmd logs,
and sbatch log files when a job launches or terminates. The base URLs for this can be configured in
the `slurm.conf` keys `SUNKNodeDashboardURL` and `SUNKJobDashboardURL`.

### 0019-empty-pids-retry

This patch changes the `_empty_pids()` function of the cgroup/v2 plugin to retry PID migration and
the enabling of subtree controllers on failure. This gets around a known issue caused by PIDs
entering the top-level cgroup during migration, resulting in failures to enable controllers in that
location due to the [no internal process constraint].

This patch will still be required as of [5a1c0174] because the race condition still exists in
`_empty_pids()`.

The race condition is described in the [source code].

[5a1c0174]: https://github.com/SchedMD/slurm/commit/5a1c017420123f0978a559788723749be043e2c8
[source code]: https://github.com/SchedMD/slurm/blob/slurm-24-11-5-1/src/plugins/cgroup/v2/cgroup_v2.c#L1387-L1394
[no internal process constraint]: https://docs.kernel.org/admin-guide/cgroup-v2.html#no-internal-process-constraint

### 0020-empty-topology

When topology.conf is empty or contains no switch/block definitions, Slurm crashes with a SEGFAULT
when interacting with the topology (node registration, node deletion, etc). The root cause was that
the topology plugins allocated a context but freed it on validation failure, leaving plugin_ctx as
NULL, which was then dereferenced in subsequent operations. The fix ensures that an empty but valid
context (with switch_count=0 or block_count=0) is retained instead of being freed and set to NULL.

This patch can be removed once it has been fixed upstream.

### 0021-revert-remove-cg-limits.patch

This patch reverts the following commit to allow SlurmdSpecOverride to work in cgroupv1 setups by
allowing the constraints detected by hwloc to persist.

[Slurm Commit](https://github.com/SchedMD/slurm/commit/e4c8a1755e5a58523f85da02a7a4ca6ed057a4a2)

### 0022-move-persist-conn-shutdown.patch

This fixes a race condition when using persistent connections
in `slurm_persist_conn_recv_server_fini` and `_service_connection`.
When a shutdown is signaled via reconfigure, there is a race between the call to
`pthread_detach` in `_service_connection` and `slurm_thread_join` in
`slurm_persist_conn_recv_server_fini`. This patch adds a guard around `pthread_detach`
to only run when we are not shutting down.

Notes from `pthead_detch` man
>       Once a thread has been detached, it can't be joined with
>       pthread_join(3) or be made joinable again.

### 0023-fail-bad-constraints.patch

In SLURM when a job fails due to not being able to meet the segment size requirements, the reason is `FAIL_BAD_CONSTRAINTS`. When a job is in this state, it is set to priority = 0, which is a held state. The scheduler will skip evaluating the job on future runs.

This patch is to change it so that jobs that fail for unmet segment size requirements to not hold the job. So that if there are topology changes to the cluster, that can satisfy the job requirements, the job can still schedule. This will set the job reason to `Reason=Resources` instead of `Reason=BadConstraints`.

### 0024-hetjob-sticky-preempt.patch

This patch keeps a heterogeneous job start attempt sticky after preemption has begun.
Without it, backfill can start one hetjob component, fail a later component while
preempted jobs are still completing, roll back the already-started component, and
then replan against a different target set. The patch adds
`bf_hetjob_sticky_preempt_timeout`, defaulting to 30 minutes, so the scheduler can
wait for preempted jobs to finish cleanup before rolling back.

This is a local workaround for a production scheduling issue. It may be replaceable
with an upstream fix if Slurm gains commit-style hetjob preemption semantics.

### 0025-hetjob-pinned-plan.patch

This patch pins hetjob immediate starts to the exact node bitmap selected by
backfill. The unpatched path records `SchedNodeList` for display and reservation
state, but `_het_job_start_now()` rebuilds a broad availability bitmap before
calling `_start_job()`. On fragmented partitions that fresh search can fail to
reconstruct the same concrete preemption plan and return `Requested nodes are busy`
even when the displayed `SchedNodeList` is all preemptible.

The patch stores the selected backfill bitmap on each het component record and
intersects the immediate-start availability bitmap with that plan before calling
`_start_job()`. Since `_start_job()` already treats its bitmap argument as excluded
nodes, this forces `select/cons_tres` to validate and allocate the committed
backfill plan instead of doing a broad fresh search. If the planned nodes are no
longer available, the scheduler fails the committed attempt and rolls back rather
than preempting an unrelated replacement set.

### 0026-hetjob-planned-preemptions.patch

This patch stores the QOS-preemptible victim job IDs that overlap each planned
hetjob component bitmap. It covers the case where backfill has a concrete
`SchedNodeList`, but the runtime `RUN_NOW` selection path returns
`ESLURM_NODES_BUSY` before producing an actionable `preemptee_job_list`.

When that happens on a pinned hetjob start, the scheduler now preempts the
stored victims on the pinned bitmap and enters the existing sticky wait path.
This makes the planned node bitmap and the victim list part of the same commit
attempt, instead of repeatedly forecasting a workable plan without starting
preemption.

### 0027-hetjob-launch-transaction-clean.patch

This patch replaces the incremental heterogeneous-job launch behavior with a
single backfill launch transaction. After normal eligibility checks, it commits
the exact node, victim, partition, QOS, and reservation plan; hides those nodes
from competing schedules; and retries that exact plan while preempted jobs
finish. The default `bf_hetjob_commit_timeout` is 30 minutes.

### 0028-job-launch-transaction-clean.patch

This patch extends launch transactions to ordinary jobs. It pins the selected
nodes and planned victims, prevents main-scheduler rerouting, and retries the
committed plan while preemptions clear. Ordinary and heterogeneous transactions
also reject overlapping commits, so the first validated transaction owns the
nodes until it starts, fails validation, or reaches its timeout. The default
`bf_job_commit_timeout` is 30 minutes.

### 0029-hetjob-launch-all-components.patch

This patch makes a committed heterogeneous-job launch plan immutable, starts
planned preemptions for every pending component before attempting to launch any
component, and waits until all planned victims have released their resources.
It also treats an already-active component preemption as transaction progress
rather than a hard start failure. Once any component starts, the transaction is
irrevocable: started components remain running, remaining planned nodes stay
pinned, and retries continue past the normal transaction timeout until every
component starts or the job is explicitly cancelled. Launched components are
latched per transaction, so a component finishing does not make the scheduler
forget the partial launch. Cancellation or another terminal state releases the
remaining pins without deallocating components that already launched.

### 0030-job-launch-preempt-before-start.patch

This patch fixes a false wait in ordinary-job launch transactions. `_start_job()`
can mark the target job as having preemption in progress and still return
`ESLURM_NODES_BUSY` without preempting the transaction's planned victims. The
old code treated that target-side state as sufficient proof of progress, and C
short-circuit evaluation prevented the planned-victim helper from running. The
transaction could therefore report that it was waiting for planned preemptions
even though every victim remained running with no `PreemptTime`.

Ordinary launch transactions now initiate their exact planned victims before
attempting allocation. They retry any planned victim that is still running
without a `PreemptTime`, wait while those jobs are running or completing on the
pinned nodes, and only report a preemption wait while the helper still finds an
exact planned victim occupying those nodes. A stale target-side
`preempt_start_time` can no longer keep a no-op transaction alive.

### 0031-launch-transaction-status.patch

This patch separates the short operator-facing reason for a committed launch
transaction from its detailed timing. Pending ordinary and heterogeneous jobs
now use categorical reasons such as `PreemptionPlanned`, `Preempting`, and
`HetjobPartialLaunch`, so `squeue` no longer presents the 30-minute transaction
safety timeout as though it were the expected preemption wait.

Detailed progress is written to the job's `SystemComment`, which is displayed by
`scontrol show job`. The namespaced `LaunchTxn:` comment reports the number of
blocking planned victims, the remaining grace time and effective total grace
derived from those victims' `PreemptTime` and `EndTime`, a cleanup phase after
grace expires, and the transaction's absolute safety deadline. For an
irrevocable partial heterogeneous-job launch it instead states that no automatic
timeout applies.

The scheduler only updates or clears `SystemComment` values that begin with its
own `LaunchTxn:` prefix, preserving unrelated administrator comments. It clears
owned comments when a transaction ends and removes stale owned status when the
backfill scheduler starts after a controller restart.

Categorical launch reasons are cleared independently of `SystemComment`
ownership, so preserving an administrator comment cannot leave a stale
`Preempting` reason. Heterogeneous-job status aggregation ignores components
that already launched, and an irrevocable partial launch keeps its current hold
or retry detail in the `LaunchTxn:` comment.

### 0032-launch-transaction-node-ownership.patch

This patch closes the race between planned-victim teardown and allocation of
the intended pinned job. A transaction can reach a point where no tracked victim
still overlaps its nodes while `select/cons_tres` or GRES cleanup continues to
return `ESLURM_NODES_BUSY`. Retrying alone is insufficient because the main
scheduler can allocate those freshly released nodes to another job first.

Committed ordinary and heterogeneous launch transactions now register their
exact nodes in a controller-wide ownership registry. The common run-now
selection path hides those nodes from every non-owner while allowing the owner
to retry its immutable plan. Ownership follows the existing transaction
lifecycle and partial hetjob launches remain irrevocable. See
[`LAUNCH_TRANSACTIONS.md`](LAUNCH_TRANSACTIONS.md) for the production incident,
design alternatives, invariants, limitations, and regression matrix.

### 0033-launch-transaction-reliability.patch

This patch hardens launch transactions against review findings from the `0032`
review; the ownership design is unchanged. Ordinary and hetjob plan validation
now check planned-node health on the cheap per-iteration maintenance pass, so
a DOWN, DRAINING/DRAINED, or FAIL planned node invalidates and releases the
plan promptly instead of stalling the pinned retry until the safety timeout
while healthy planned nodes sit fenced and idle. An irrevocable partial hetjob
launch with an invalid plan is still held, but once a hold persists past five
minutes every hold path emits a rate-limited `error()` log naming the reason
so the wedge is operator-visible.

Ordinary transactions also gain a queue-match watchdog: if backfill keeps
scanning its queue but no record has matched the committed plan for two
minutes (for example the owner's QOS was changed or the committed reservation
was deleted), the plan is invalidated for replanning instead of the owner
being silently skipped until the safety timeout. The match stamp and watchdog
clock are taken during the same pre-cycle queue scan, so long or aborted
backfill cycles cannot cause spurious invalidation, and job attributes are
deliberately not compared directly because `qos_ptr`/`resv_ptr`/`resv_id` are
per-queue-record scratch state. The queue-record match now also mirrors the
commit path for plain `--reservation` jobs, whose committed plans previously
could never match and always expired at the safety timeout.

A successful pinned start of a job-array task clears launch-transaction state
from the started record after `job_array_split()` reassigns job IDs, so a
later requeue is not invisible to the main scheduler. The backfill agent
teardown destroys the hetjob transaction list while the job write lock is
still held, since its destructor mutates job records. Transaction lifecycle
events now log at `info` level: opens with pinned-node and planned-victim or
component counts, releases/invalidations/timeouts with the reason.

### 0034-launch-transaction-bounded-replan.patch

This patch prevents a failed committed plan from immediately selecting and
preempting a replacement victim set. Once any planned victim has entered
preemption, an invalid or timed-out ordinary or not-yet-started heterogeneous
transaction first enters a cleanup state. It keeps the original node fence,
waits without sending any new preemption requests, and releases the fence only
after the original victims have left. The owner then waits a configurable
cooldown before one bounded replacement plan is allowed. A second failed
victim plan is blocked for operator review instead of creating an unbounded
preemption storm. Defaults are
`SchedulerParameters=bf_launch_replan_delay=300,bf_launch_max_replans=1`.

Non-`ESLURM_NODES_BUSY` start errors no longer discard a valid committed plan
mid-grace. The scheduler retains the exact nodes and victims and retries that
same start every five seconds until it succeeds, validation fails, or the
existing commit safety timeout expires. This does not change QOS preemption
semantics: `slurm_job_preempt()` remains authoritative, so a configured
five-minute `GraceTime` is neither hardcoded nor shortened by this patch.

Before a heterogeneous launch allocates its first component, every remaining
component must pass an exact `SELECT_MODE_RUN_NOW` check on its pinned bitmap
with no replacement preemptee candidates. This closes the common resource and
GRES race where one component started while another was already unable to
allocate. Components are still launched sequentially after the barrier, so a
hardware failure in that final interval remains possible. If any component has
already started, the launch stays irrevocable and visible; Slurm never rolls
back the running component automatically.

Finally, reservation creation, resource-changing reservation updates, and
automatic reservation node selection now exclude nodes owned by active launch
transactions, including `MAINT` and `OVERLAP` placement. The short-lived launch
commit wins; an operator can cancel the owner before placing an emergency
reservation on those exact nodes. Retry and block state is controller-local
and is cleared with stale transaction status when the backfill agent restarts.

### 0035-launch-transaction-minimal-victims.patch

This patch prevents a small job on a consumable-resource node from preempting
every preemptible job resident on that node. The transaction planner previously
used `SELECT_MODE_WILL_RUN` to reconstruct victims for an already-selected
bitmap. In `select/cons_tres`, that mode returns every preemptible candidate
overlapping the selected nodes. A four-CPU job therefore selected 32 six-CPU
victims and disrupted all 192 CPUs on one shared node.

Pinned victim reconstruction now uses Slurm's existing
`SELECT_MODE_RUN_NOW` preemption simulation. That algorithm removes candidates
until the request fits and returns the sufficient victim prefix selected by
Slurm's normal run-now ordering. The helper detaches any existing
`job_resrcs`, copies the resulting victim IDs, discards the simulated
allocation, and restores the original pointer. It never allocates nodes or
signals victims during planning. The simulator also runs against temporary
copies of the job's GRES request state so a GPU selection cannot leak into the
pending job record.

The patch also prevents two schedulers from initiating independent plans for
the same ordinary job. When submit-time or main-scheduler allocation finds that
a job needs preemption, it records a per-job handoff and returns nodes busy
without signaling preemptees. Backfill promotes handoff jobs ahead of its
normal scan limits and evaluates them for immediate launch even when ordinary
per-user or license scan filters would have skipped them. Backfill then
selects, registers, and signals the single committed plan.

A handoff grants one prompt backfill attempt rather than creating an unbounded
retry loop. Backfill drops it if the owner has no queue record, is held, or is
no longer pending. Once a promoted record passes cycle-wide budget and yield
checks, either a job-specific eligibility rejection or a selection that does
not open a transaction moves the marker into a non-active 120-second cooldown.
Submit-time and main scheduling still cannot signal a competing victim set,
but the marker does not force one-second backfill cycles. Records deferred by
cycle-wide limits retain their active handoff until they receive that first
job-specific consideration, and handoffs created while backfill temporarily
yields survive until the next queue scan.

The handoff is enabled directly from the live scheduler configuration only
while ordinary launch transactions and `sched/backfill` are enabled. A failed
run-now victim simulation is returned separately from an empty victim list, so
neither ordinary jobs nor hetjob components can fall through to an uncommitted
start attempt; its handoff enters cooldown after that backfill attempt, and a
fresh active handoff cannot be created until the cooldown marker expires.
Setting `bf_job_commit_timeout=0` restores the legacy
non-transactional preemption path. QOS `GraceTime` remains authoritative after
the transaction signals its selected victims.

### 0036-launch-transaction-visibility.patch

This patch exposes the exact node plan already owned by an active launch
transaction. Ordinary jobs publish their committed bitmap as `SchedNodeList`;
each pending heterogeneous-job component publishes its own committed bitmap.
Backfill preserves that value only while the matching transaction is committed
or draining cleanup, then clears it when ownership is released or a bounded
replan enters cooldown. The displayed nodes therefore describe the immutable
plan being retried rather than a disposable backfill estimate.

The launch status collector also intersects every current blocker with the
committed bitmap and adds the compressed blocker nodes to the namespaced
`SystemComment`. The node expression is capped at 256 characters and marked as
truncated when necessary. `SchedNodeList` remains the complete committed plan;
the comment names only nodes still occupied by tracked blocking jobs.

This is an observability-only change. It does not select nodes, signal jobs,
alter QOS grace time, change transaction ownership, or modify launch and replan
decisions.

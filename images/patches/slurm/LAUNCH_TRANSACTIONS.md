# Launch Transaction Design

## Objective

Preemption must have commit semantics for both ordinary and heterogeneous jobs:

1. Backfill selects one concrete node and victim plan.
2. Slurm commits that plan before initiating any victim preemption.
3. QOS grace time is honored normally.
4. The intended job retries the same nodes while victims exit and node/GRES cleanup finishes.
5. Other jobs cannot acquire committed nodes between victim cleanup and launch.
6. If a committed plan becomes invalid after victim signaling, it drains that original attempt
   before any bounded replacement plan can form.
7. The transaction ends only after launch, cancellation, terminal state, safe cleanup, or its
   safety timeout policy.

The important property is not merely that enough aggregate capacity exists. Once Slurm preempts
jobs for a concrete plan, the resulting capacity must remain owned by that transaction until the
intended launch has had a reliable opportunity to consume it.

## 2026-07-13 Incident

Ordinary job `2131756` committed a 24-node GPU plan with 87 blocking jobs. Slurm initiated the
planned preemptions and honored their configured grace periods. The launch then encountered this
sequence:

- At `14:24:45`, `_start_job()` returned `ESLURM_NODES_BUSY` for the exact pinned plan.
- The planned victim records no longer appeared to overlap the nodes, so the backfill plugin
  released the launch transaction and allowed replanning.
- At `14:24:50`, later job `2131761` acquired eight of the nodes released for `2131756`.
- Job `2131756` remained pending with `Reason=Resources` and a different `SchedNodeList`.

This means jobs were preempted for `2131756`, but that launch attempt did not receive the capacity
it created. The job did not enter a terminal failed state; it returned to normal pending/replanning.
That distinction does not make the behavior safe: repeated replanning can preempt another victim
set and create a preemption storm without making forward progress.

## Root Cause

There are two independent races.

### Victim teardown gap

A victim can stop appearing as a running or completing job on the pinned bitmap before
`select/cons_tres`, GRES, or node accounting is ready to allocate those nodes. During this gap,
`_start_job()` correctly reports `ESLURM_NODES_BUSY`, but a victim-record-only progress check can
incorrectly conclude that the transaction has nothing left to wait for.

Patch `0030-job-launch-preempt-before-start.patch` intentionally stopped trusting the target job's
stale `preempt_in_progress` and `preempt_start_time` flags. Restoring those flags as the wait
condition would reintroduce the earlier no-op transaction that waited without initiating the
planned victims.

### Main-scheduler ownership gap

The backfill plugin's transaction bitmaps prevent competing backfill plans from overlapping, and
`bf_launch_transaction` prevents the main scheduler from rerouting the transaction owner. Neither
mechanism prevents the main scheduler from allocating freshly released transaction nodes to a
different job. Retrying the pinned launch is therefore necessary but insufficient.

## Selected Fix

Patch `0032-launch-transaction-node-ownership.patch` adds controller-wide, in-memory ownership for
committed launch-transaction nodes.

- An ordinary transaction registers its exact node bitmap under the job ID.
- A heterogeneous transaction registers the union of every component bitmap under the hetjob ID.
- The common run-now node-selection path removes transaction-owned nodes for every non-owner job.
- The owning ordinary job, or any component of the owning hetjob, remains eligible to allocate its
  exact pinned nodes.
- `ESLURM_NODES_BUSY` remains retryable after victim records disappear, covering node and GRES
  cleanup latency without changing plans.
- Ownership is released with the existing transaction lifecycle: successful launch, validation
  failure, cancellation or terminal state, plugin teardown, or the configured safety timeout.
- Once any hetjob component starts, the transaction remains irrevocable and has no automatic
  timeout. Started components are never rolled back merely because another component is waiting.

The registry is protected independently from scheduler thread lifecycle, but it does not persist
across a `slurmctld` restart. Launch transactions themselves are also in-memory state; after a
restart, normal scheduling and stale-status cleanup resume without reconstructing an old commit.

## Follow-Up Hardening

Patch `0033-launch-transaction-reliability.patch` closes review findings against `0032` without
changing the ownership design:

- Ordinary and hetjob validation now check planned-node health on the cheap per-iteration
  maintenance pass. A planned node that is DOWN, DRAINING/DRAINED, or FAIL invalidates the plan
  promptly instead of stalling the pinned retry until the safety timeout while the remaining
  planned nodes sit fenced and idle. DRAINING nodes previously passed validation (they leave
  `avail_node_bitmap` but stay in `up_node_bitmap`), so a single drained node silently blocked the
  whole plan. NOT_RESPONDING is deliberately ignored as transient.
- For an irrevocable partial hetjob launch, an invalid plan is still held rather than released.
  Once a hold has persisted for five minutes, every hold path emits a rate-limited `error()` log
  (at most one per five minutes) naming the reason, including the failed node for node-health
  holds, so a permanent wedge is not an invisible capacity leak while a transient hold that
  resolves quickly never alarms. Cancelling the hetjob remains the operator action.
- Ordinary transactions now carry a queue-match watchdog. The owner is only retried through queue
  records that exactly match the plan's frozen partition, QOS, reservation, and prefer values; if
  backfill keeps scanning its queue but no record has matched the plan for two minutes (for
  example the job's QOS was changed or the committed reservation was deleted), the plan is
  invalidated for replanning instead of the owner being silently skipped until the safety timeout.
  The match stamp and the watchdog clock are both taken during the same pre-cycle queue scan, so a
  healthy owner can never fall behind the clock however long a backfill cycle runs or wherever it
  breaks out, and the watchdog stays dormant when backfill is not scanning (the commit timeout
  remains the backstop). Job attributes are deliberately not compared directly, because
  `qos_ptr`/`resv_ptr`/`resv_id` are per-queue-record scratch state rewritten by the schedulers.
- The queue-record match now mirrors the commit path for reservations. A plain `--reservation`
  job's queue records carry no reservation pointer, so the previous match compared the committed
  reservation against zero and could never match: such owners were silently skipped every cycle
  and their transactions always expired at the safety timeout. The match now falls back to the
  job's own reservation exactly as the commit path does.
- A successful pinned start of a job-array task no longer leaves `bf_launch_transaction` set on the
  started record after `job_array_split()` moves the original job ID to the new pending meta
  record. Previously a later requeue of that task was silently skipped by the main scheduler.
- The backfill agent teardown now destroys the hetjob transaction list while the slurmctld job
  write lock is still held; its destructor mutates job records.
- Transaction lifecycle events now log at `info` level, so they are visible without
  `DebugFlags=Backfill,Hetjob`: open events include pinned-node and planned-victim or component
  counts; release, invalidation, and timeout events include the reason.

## Bounded Replan State Machine

Patch `0034-launch-transaction-bounded-replan.patch` makes invalidation safe after preemption has
started. It distinguishes a plan that can be discarded without side effects from one that has
already disrupted victim jobs.

```text
PLANNED -> COMMITTED -> PREEMPTING -> READY -> STARTED
                         |
                         +-> CLEANUP -> COOLDOWN -> one replacement plan
                                                   |
                                                   +-> BLOCKED after another failed victim plan
```

- Before the first victim signal, validation can reject a stale plan immediately.
- After any planned victim is signaled, validation failure or the 30-minute safety deadline moves
  the transaction to `CLEANUP`. The exact node fence remains active, the scheduler only observes
  the original victim IDs, and no replacement victim can be selected or signaled.
- Once those victims have left, the fence is released and the owner enters a default 300-second
  cooldown. `bf_launch_replan_delay` configures this failure backoff; it is separate from QOS
  `GraceTime` and is not encountered on a successful plan.
- `bf_launch_max_replans` defaults to one. If that one replacement victim plan also fails after
  signaling, the owner remains pending and blocked with an operator-visible `SystemComment`
  instead of beginning a third preemption wave. Cancel and resubmit to authorize a fresh attempt.
- A transient start return other than `ESLURM_NODES_BUSY` retains the same committed nodes and
  victims and retries the exact start every five seconds. It does not reopen planning mid-grace.
- Backfill restart clears controller-local retry/block state along with stale transaction status.

For heterogeneous jobs, every not-yet-started component must pass an exact run-now select test on
its pinned bitmap, with no preemptee candidates, before the first component is allocated. This is
an all-components-ready barrier against node, CPU, and GRES cleanup races. Allocation calls remain
sequential, so no software patch can make a hardware failure between those calls impossible. If a
component has already started, the transaction remains irrevocable: running work is never rolled
back automatically, remaining nodes stay fenced, and a persistent failure requires operator
recovery or cancellation.

New reservation placement is also fenced. Explicit reservation creation, resource- or time-changing
updates, and automatic node selection remove launch-owned nodes even for `MAINT` and `OVERLAP`
reservations. An active launch commit therefore wins for its bounded lifetime; cancel the owner
first when an emergency reservation must claim those exact nodes.

## Mitigation Levers

`SchedulerParameters=bf_job_commit_timeout=0` plus `scontrol reconfigure` disables new ordinary
launch transactions and drains open ones on the next backfill cycle. Setting
`bf_hetjob_commit_timeout=0` prevents new hetjob commits; a not-yet-started committed transaction
finishes safe victim cleanup before returning to ordinary planning. An already partially launched
hetjob remains irrevocable and must be cancelled explicitly. Rolling back the controller image to
the `0031` stack (not lower) plus `bf_job_commit_timeout=0` is the safe interim mitigation if the
ownership stack must be reverted; a controller restart clears all in-memory ownership and bounded
replan state.

## Alternatives Considered

### Trust target preemption flags

Rejected. Those flags can be set even when no planned victim was preempted. They caused the stuck
ordinary-job behavior fixed by patch 0030.

### Retry only while nodes are busy

Rejected as incomplete. It closes the victim teardown gap, but a different main-scheduler job can
still acquire a released node before the next backfill retry.

### Raise the owner's priority

Rejected. Priority is policy, not ownership. A temporary priority mutation would be difficult to
restore correctly, would affect unrelated scheduling decisions, and still would not make a
multi-component hetjob launch atomic.

### Create synthetic Slurm reservations

Rejected for now. Reservations are persisted and policy-visible objects with accounting,
validation, and lifecycle semantics much broader than this short-lived internal commit. Using them
would make the patch substantially more invasive.

### Mark nodes with `NODE_STATE_PLANNED`

Rejected. That state represents normal backfill planning and is not an exclusive allocation guard
against a higher-priority main-scheduler decision.

## Invariants

The combined patch stack is intended to maintain these invariants:

1. A transaction stores one immutable node, victim, partition, QOS, and reservation plan.
2. All planned hetjob component preemptions begin before any component launch is attempted.
3. Only planned victims are initiated by the transaction; it never substitutes a new victim set.
4. Committed nodes are unavailable to every non-owner run-now selection.
5. `ESLURM_NODES_BUSY` retries the exact plan instead of releasing it merely because victim job
   records have disappeared.
6. A validation failure after victim signaling enters cleanup and cannot select replacement
   victims until every original victim has left and the bounded cooldown has elapsed.
7. Ordinary jobs and not-yet-started hetjobs retain the configured 30-minute safety timeout.
8. Before the first hetjob component starts, every remaining component passes an exact run-now
   readiness test on its pinned nodes without replacement preemptee candidates.
9. A partial hetjob launch is irrevocable and continues retrying remaining components without an
   automatic timeout or rollback.
10. Reservation placement cannot consume transaction-owned nodes while the commit is active.
11. Terminal job state releases ownership rather than leaving stale capacity hidden from the
    scheduler.
12. QOS grace time remains authoritative; node ownership, cleanup, and replan cooldown do not
    shorten or bypass it.

These guarantees do not make launch unconditional. A node can fail, be drained, lose required
features, or become invalid for a reservation. Before preemption starts, such a validation failure
can discard the plan immediately. After victim signaling, it first drains the original attempt and
then permits only the configured bounded replan. The guarantee is narrower and essential: another
scheduler or reservation path cannot steal a still-valid transaction's committed nodes, and an
invalid plan cannot immediately create another victim wave.

Preemption is job-level. If one planned victim spans nodes outside the intended node bitmap,
preempting that victim can release more physical nodes than the new job requests. The transaction
does not add replacement victims or broaden its selected node bitmap, but it cannot partially
preempt only one allocation of a multi-node victim job.

## Expected Operator Signals

- `Reason=PreemptionPlanned`: the concrete transaction exists, but at least one planned victim has
  not yet received preemption.
- `Reason=Preempting`: grace, victim exit, or pinned-node cleanup is in progress.
- `Reason=HetjobPartialLaunch`: at least one component started and remaining components are still
  committed.
- `Reason=... cleanup complete; replan in ...`: the original victims are gone, the node fence has
  been released, and the failure cooldown is active.
- `Reason=... blocked after ... failed replans`: the configured replacement-plan limit was reached;
  cancel and resubmit after operator review to authorize another victim wave.
- `SystemComment=LaunchTxn: ... grace ...`: QOS grace is currently the expected wait.
- `SystemComment=LaunchTxn: preemption complete; waiting for pinned nodes to finish cleanup ...`:
  victim records cleared, but the exact launch still returns `ESLURM_NODES_BUSY`.

## Regression Matrix

Before production rollout, exercise at least these cases and inspect controller logs, `squeue`,
`scontrol show job`, victim `PreemptTime`, and final node allocation:

| Case | Required result |
| --- | --- |
| Ordinary job, no preemption | Starts normally; no lingering ownership |
| Ordinary job, five-minute grace | Victims receive preemption once; owner starts on the pinned nodes after grace and cleanup |
| Later higher-priority job arrives during cleanup | Later job cannot acquire committed nodes; it uses other capacity or remains pending |
| Ordinary transaction exceeds safety timeout after signaling victims | No new victims are selected; original victims drain, ownership releases, and the bounded replan cooldown begins |
| Hetjob with multiple preempting components | Every component's planned victims are initiated before the first component starts |
| Hetjob victims have exited but one component's GRES is still busy | No component starts until every exact component plan passes the run-now readiness barrier |
| Hetjob component hits cleanup delay | Already-started components remain running; delayed component retries its exact bitmap |
| Hetjob cancelled before any component starts | Ownership and transaction status clear |
| Hetjob cancelled after partial launch | Remaining ownership clears without scheduler-driven rollback of started components |
| Planned node goes DOWN, DRAINING/DRAINED, or FAIL (ordinary job, before victim signal) | Validation invalidates and releases the transaction promptly |
| Planned node goes DOWN, DRAINING/DRAINED, or FAIL (ordinary job, after victim signal) | Transaction enters cleanup, sends no replacement preemptions, then applies the bounded cooldown/replan policy |
| Planned node goes DOWN, DRAINING/DRAINED, or FAIL (hetjob, no component started) | Before signaling it invalidates immediately; after signaling it drains the original victims before bounded replanning |
| Planned node goes DOWN, DRAINING/DRAINED, or FAIL (hetjob, partial launch) | Transaction is held (irrevocable) with the failed node named in a rate-limited `error()` log until the node recovers or the hetjob is cancelled |
| Owner QOS or reservation changed mid-transaction (`scontrol update`) | Queue-match watchdog invalidates and releases the transaction within about two minutes of backfill queue scans instead of silently skipping the owner until the safety timeout |
| Job submitted with a QOS or reservation list (`--qos=a,b`) owns a transaction | Transaction survives main-scheduler passes over the job's other queue records; no spurious invalidation |
| Job submitted with a plain `--reservation` owns a transaction | Owner's retries match its committed plan and it starts on the pinned nodes (previously it could never match and always expired at the safety timeout) |
| Backfill cycle runs longer than two minutes (large `bf_max_time`) with healthy transactions | No spurious watchdog invalidation |
| Job-array owner starts on its pinned plan | Started task carries no launch-transaction state; a later requeue of that task schedules normally |
| Non-`ESLURM_NODES_BUSY` start error during grace | Exact transaction remains committed and retries after five seconds; no new nodes or victims are selected |
| First failed victim plan | Original victims drain, nodes unfence, and exactly one replacement plan is allowed after the default 300-second cooldown |
| Replacement victim plan also fails | Owner remains pending with a blocked `SystemComment`; no third victim wave occurs |
| Explicit, automatic, `MAINT`, or `OVERLAP` reservation targets committed nodes | Reservation uses other nodes or returns nodes busy; it cannot acquire the launch-owned nodes |
| `bf_job_commit_timeout=0` set via reconfigure with open transactions | New ordinary transactions stop and open ones drain; a not-yet-started het transaction finishes safe cleanup, while a partial launch requires explicit cancellation |
| Controller restart during a transaction | In-memory ownership is gone and stale `LaunchTxn:` status is cleared on backfill startup |

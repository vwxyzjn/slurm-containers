# Launch Transaction Design

## Objective

Preemption must have commit semantics for both ordinary and heterogeneous jobs:

1. Backfill selects one concrete node and sufficient victim plan.
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

## 2026-07-13 Shared-Node Over-Preemption Incident

Ordinary job `2135825` requested four CPUs and 16 GiB on one `turin-cpu-shared` node. At
`21:53:53`, less than one second after submission, a non-backfill allocation path signaled one
two-CPU victim on `slurm-turin-cpu-shared-220-197`. At `21:54:02`, backfill selected a different
node, `slurm-turin-cpu-shared-220-221`, and signaled every preemptible job on it: 32 jobs at six
CPUs each, consuming all 192 effective CPUs. The configured 300-second QOS grace was honored, but
the victim set was grossly larger than the four-CPU request. The owner eventually started on
`220-221` at `22:01:20`.

Two independent behaviors caused this incident:

- Transaction victim reconstruction used `SELECT_MODE_WILL_RUN`. The `select/cons_tres`
  implementation appends every preemptible candidate overlapping the selected bitmap in that
  mode; it does not stop after enough CPUs, memory, and GRES have been recovered.
- Submit-time or main-scheduler `select_nodes()` could signal a preemption before backfill created
  a transaction. Slurm treats `preempt_in_progress` as queue-build scratch state and clears it
  while rebuilding scheduler queues, so it is not a durable handoff between the two schedulers.
  Backfill could therefore commit and signal a second, disjoint plan for the same owner.

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

## Minimal Victims and Scheduler Handoff

Patch `0035-launch-transaction-minimal-victims.patch` makes backfill the only preemption initiator
for an ordinary job while its launch handoff or transaction is active. Submit-time and
main-scheduler allocation still start jobs that fit on immediately free resources. If starting
would require preemption, the common selection path records a per-job handoff, returns
`ESLURM_NODES_BUSY`, and does not signal a victim. Backfill promotes handoff queue records before
ordinary records and evaluates those jobs for immediate launch even after normal
`bf_max_job_test`, per-user/per-partition, or `bf_licenses` scan filters would have skipped them.
The handoff forces a prompt backfill cycle only until its promoted queue record is attempted. The
job may therefore show `Reason=Resources` until backfill opens its transaction.

This is not a cluster-wide suppression flag. Jobs without a handoff continue through normal
submit-time and main scheduling, and configuration is read synchronously from the live
`SchedulerType`, `bf_interval`, and `bf_job_commit_timeout` values. Disabling ordinary transactions
or backfill immediately stops creating handoffs; existing markers are cleared on the next
selection or backfill maintenance pass. Terminal jobs and successful starts are pruned, and
opening a transaction consumes its handoff atomically with registering node ownership. A handoff
is also released when its owner has no freshly built backfill queue record, is held or no longer
pending. If its promoted queue record reaches a real selection test but the cycle ends without a
commit, the marker becomes non-active for a 120-second cooldown. The same transition occurs when
the promoted record passes cycle-wide budget and yield checks but a job-specific eligibility test,
such as a changed accounting limit or dependency, rejects it before selection. A record deferred
by a cycle-wide timeout, RPC-pressure yield, or backfill budget retains its active handoff until a
later cycle can actually consider the job. During cooldown, submit-time and main scheduling still
defer preemption, but the marker neither receives promotion nor forces one-second backfill cycles;
normal-cadence backfill may still start the job or open its transaction. After the cooldown
expires, normal scheduling may create a fresh active handoff. Handoffs created while backfill
yields are generation-stamped and survive until the next complete queue scan.

For the already-selected pinned bitmap, backfill now calls the normal `SELECT_MODE_RUN_NOW`
preemption simulator rather than `SELECT_MODE_WILL_RUN`. It detaches the pending job's existing
resource pointer and runs against temporary copies of its GRES request state before the test. It
frees the simulated allocation and GRES state afterward, so planning cannot allocate or mutate the
pending job. The returned victim IDs are the sufficient prefix chosen by Slurm's normal run-now
preemption ordering. Backfill commits node ownership and those IDs before it calls
`slurm_job_preempt()`, after which the victims' configured QOS `GraceTime` remains authoritative.
The simulator also returns its status separately from the victim list. Any simulation error stops
that attempt; it cannot be mistaken for a successful plan with no victims and cannot fall through
to `_start_job()` outside a transaction. At cycle end, an unsuccessful prompt attempt enters the
non-active cooldown rather than creating an unbounded
one-second retry loop or immediately allowing another scheduler to signal victims.

Victims remain indivisible jobs. A four-CPU request can preempt one six-CPU job, and one selected
multi-node victim can release nodes outside the pinned bitmap. The patch prevents selecting every
colocated candidate and prevents parallel scheduler plans; it does not split a victim allocation
or redefine Slurm's preemption ordering policy.

## Mitigation Levers

`SchedulerParameters=bf_job_commit_timeout=0` plus `scontrol reconfigure` disables new ordinary
launch handoffs and transactions, restores submit-time and main-scheduler preemption, clears
uncommitted handoff markers, and drains open transactions on the next backfill cycle. Setting
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

1. With ordinary launch transactions enabled, a submit-time or main-scheduler selection that needs
   preemption creates one per-job handoff and never initiates a competing victim plan; backfill
   promotes the handoff and owns victim selection and signaling. Each handoff grants one prompt
   backfill attempt and becomes a non-active cooldown marker if that attempt cannot commit.
2. A transaction stores one immutable node, victim, partition, QOS, and reservation plan.
3. The planned victim list is the sufficient prefix selected by Slurm's run-now preemption
   algorithm for the exact pinned bitmap, not every preemptible job resident on those nodes.
4. All planned hetjob component preemptions begin before any component launch is attempted.
5. Only planned victims are initiated by the transaction; it never substitutes a new victim set.
6. Committed nodes are unavailable to every non-owner run-now selection.
7. `ESLURM_NODES_BUSY` retries the exact plan instead of releasing it merely because victim job
   records have disappeared.
8. A validation failure after victim signaling enters cleanup and cannot select replacement
   victims until every original victim has left and the bounded cooldown has elapsed.
9. Ordinary jobs and not-yet-started hetjobs retain the configured 30-minute safety timeout.
10. Before the first hetjob component starts, every remaining component passes an exact run-now
   readiness test on its pinned nodes without replacement preemptee candidates.
11. A partial hetjob launch is irrevocable and continues retrying remaining components without an
   automatic timeout or rollback.
12. Reservation placement cannot consume transaction-owned nodes while the commit is active.
13. Terminal job state releases ownership rather than leaving stale capacity hidden from the
    scheduler.
14. QOS grace time remains authoritative; node ownership, cleanup, and replan cooldown do not
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

- `Reason=Resources` immediately after submission: no victim has been signaled yet; the job is
  waiting for backfill to consume its handoff and commit one transaction plan.
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
| Four-CPU ordinary job on a full 192-CPU shared node with 32 six-CPU preemptible jobs | Exactly one sufficient six-CPU victim is selected and signaled; the other 31 continue running |
| Submit-time and main scheduling evaluate a job before backfill commits | No victim receives `PreemptTime`; backfill later opens and signals one plan without a disjoint preliminary victim set |
| Handoff job lies beyond `bf_max_job_test` or a configured per-user/per-partition backfill scan limit | Its queue record is promoted and receives an immediate transaction evaluation without creating a future reservation |
| Handoff job needs license preemption while `bf_licenses` is unset | Backfill performs the immediate run-now transaction test; it either commits a sufficient victim plan or leaves the job pending without signaling anyone |
| Handoff owner is held, cancelled, or absent from the next built backfill queue | Handoff releases without forcing repeated one-second backfill cycles |
| Handoff is created while backfill has yielded its locks | The new marker survives the current cycle cleanup and receives one attempt from the next complete queue scan |
| Handoff owner becomes ineligible because an accounting limit or dependency changes | Once its promoted record is considered, the handoff enters non-active cooldown without signaling victims or forcing repeated one-second cycles |
| Cycle budget, RPC pressure, or a state-changing yield interrupts before a promoted handoff receives job-specific consideration | Active handoff survives and is promoted again; it is not discarded before its first consideration |
| Pinned run-now victim simulation returns an error | No transaction is created, neither `_start_job()` nor any victim signal occurs for that attempt, and the handoff enters non-active cooldown instead of hot-looping or being immediately recreated |
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
| `bf_job_commit_timeout=0` set via reconfigure with open transactions | New ordinary transactions stop, legacy submit/main preemption resumes, and open ones drain; a not-yet-started het transaction finishes safe cleanup, while a partial launch requires explicit cancellation |
| Controller restart during a transaction | In-memory ownership is gone and stale `LaunchTxn:` status is cleared on backfill startup |

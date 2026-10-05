# Shared-node array preemption: joblaunch11 candidate

Apply `0038-array-node-batches.patch` after the complete joblaunch10 stack
through `0037`. It is opt-in and changes the controller/backfill scheduler,
not compute-node images. Build the complete Slurm install and Pyxis with
the existing `controller-rebuilt-slurm` target; do not overlay only one plugin.
The Docker build runs all nine array transaction/batch regression groups.

An operator-reviewed configuration for eight-GPU shared nodes is:

```text
bf_max_job_array_launch=100,bf_max_job_array_node_batch=8
```

The selector checks the combined CPU, memory and GPU request for compatible
single-node, one-GPU array tasks. Every task gets a committed plan and a
reserved array slot before any victim is signaled. Only explicitly admitted
members share the node fence. A task that has not joined that batch, even
from the same array, remains excluded.

The preparation cap counts tasks, not batches. Running plus reserved slots
still obey `%N`; 100 is not a limit on array length or running tasks. Victims
keep their configured 300-second grace. Members wait for the selected
victim set to finish cleanup, then start independently. Started tasks are
never rolled back because a sibling is delayed.

The default node-batch size is 1 (disabled), range 1 through 32. Returning
it to 1 stops new batches without discarding existing plans. Unsupported
requests retain the existing independent-task behavior. This is not a
general resource-level reservation implementation or a guarantee of future
eligibility after holds, account limits or node-health changes.

Local validation includes a real controller with synthetic GPU GRES and
non-cooperating victims: eight members allocate together after full 300-second
grace plus cleanup; a two-member batch preempts only two victims and leaves
six residents running. Physical GPU cleanup, production QOS/account limits,
multiple competing arrays and controller responsiveness at scale remain
operator rollout gates.

GitOps lives in `periodiclabs/periodic-mono/infra/gitops/`. The former
`xanderdunn/periodic-coreweave-gitops` repository is archived. Only prepare
reviewable PRs; do not merge, Argo sync or override live images. AWS6/AWS7
currently auto-sync, so a human merge may itself initiate rollout.

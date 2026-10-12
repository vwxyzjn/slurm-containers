<!--
SPDX-FileCopyrightText: 2026 Periodic Labs
SPDX-License-Identifier: GPL-2.0-or-later
SPDX-PackageName: slurm-containers
-->

# CW2 fault-tolerance image candidate

Patches 0039–0042 add component-local node failure, per-component batch
scripts, dynamic joins, and batch-launch generation fencing to the complete
Slurm 25.05.3 stack through 0038. They are copied byte-for-byte from the
review copies in periodic-mono/infra/slurm. Their source is prototype commit
`c5dd2b9640f8a1e7fe1d7e436dc9f36c908fe19e`; the earlier canonical image source
is `f062e2d8953c4561d3f2ab753ed2e55abc28a85b`.

The same complete Slurm install and newly built Pyxis are copied into four
digest-pinned runtimes. No package-manager upgrade or replacement of CUDA,
NCCL, Enroot, conda, NHC, or other runtime extras is performed.

The common Slurm build explicitly enables NVML using CUDA 12.9's header and
link stub from the pinned compute runtime. This rebuilds `gpu_nvml.so`
against the same patched Slurm source instead of leaving the compute base's
old plugin behind. Those build inputs live only in `/opt/nvml` in the build
stage and are never copied into runtime images. The plugin loads the real
host driver's `libnvidia-ml.so` at runtime; a local CPU-only build does not
exercise GPU discovery or allocation.

| Docker target | Preserved runtime |
| --- | --- |
| `controller-rebuilt-slurm` | CW2's deployed joblaunch10 controller |
| `accounting-rebuilt-slurm` | CoreWeave controller 25.05.3-coreweave.5 |
| `login-rebuilt-slurm` | CoreWeave controller-extras 25.05.3-coreweave.5 |
| `compute-rebuilt-slurm` | CoreWeave slurmd-cw-cu129-extras 25.05.3-coreweave.5 |

Only Linux/amd64 images are prepared. The Dockerfile pins the exact amd64
manifests. Read-only registry requests from CW2 on 2026-10-12 verified that
the deployed internal-registry indexes select those same GHCR manifests:

| Runtime | Deployed internal index | Exact amd64 manifest |
| --- | --- | --- |
| accounting | `sha256:12d90d570bf47ded77497ff81985764043c1370c3287387e579929c41b7ea771` | `sha256:1bb3857d0f47b9207dca9b53847fd66c37e85ea1c2c45378c886365bd8be3cac` |
| login | `sha256:64d0281c96cb0ff1d03d4b7df8dacc32f4195a2d5fbb6da763eedcca5b25410d` | `sha256:c8cda863222ab98ca37b13972818f72c79c20636cd50a1ef961b5f6f4896bcea` |
| compute | `sha256:076f9615eea6e97e4f8af892f7a510c630c09a9896f915070ff36c0bd8ba9228` | `sha256:15c3102d270eecbb00d2940d0ee2daa84ab6b2f313bebed937aba8b9a72249e9` |

The different GHCR indexes additionally contain provenance attestations;
the executable platform manifests are identical.

## Build and publish through the existing release process

The inherited workflows require CoreWeave's `cw` runners and buildkit
secret. This fork has no such runners. This candidate follows Periodic's
existing documented local Docker build and ECR publication process; it does
not add credentials, runners, workflows, repositories, or deployment jobs.

Use a reviewed, clean source commit. Give every image a unique tag containing
that source revision and its role, and verify the published digest before
proposing a GitOps reference. All four roles can use the existing Periodic
`slurm-controller` ECR repository. For example, after choosing the full
destination image reference:

```bash
docker buildx build --platform linux/amd64 \
  --target compute-rebuilt-slurm --load \
  --tag "$destination_image" \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  --metadata-file "$build_metadata" -f images/Dockerfile images
```

Repeat for controller, accounting and login. Before publishing, verify the
installed Slurm and Pyxis checksums match the common build, required shared
libraries resolve, and runtime entrypoints/configuration and base layers
remain those of the pinned runtime. The builder executes the existing nine
launch-transaction and array-node-batch C regression groups.

## Deployment is separately reviewed

This is a coordinated protocol/state upgrade: **slurmdbd, then slurmctld,
then slurmd/slurmstepd, then login/client binaries**. Compute must not run
under the older controller. Older compute processes do not implement the
new stale-launch fencing. Existing running slurmstepd processes also need
explicit handling during the operator's drain/rollout plan.

The new job-state format cannot be losslessly downgraded with retained job
records. A successful image build is not deployment authorization. Human
review, merge and Argo sync are separate gates. No live cluster is changed
by these image targets.

Alchemy/pj integration remains separate. These patches do not make control
replica loss trigger whole-run recovery automatically. Scheduler feature
settings, application failure policy and live fault-injection testing must
be reviewed independently.

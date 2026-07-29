# oc-dr.sh — OpenShift Disaster Recovery via Velero / OADP

A comprehensive interactive shell script for performing a full OpenShift cluster disaster recovery using [Velero / OADP](https://docs.openshift.com/container-platform/latest/backup_restore/application_backup_and_restore/oadp-intro.html).  
Only requires `oc` CLI and `python3` — no separate `velero` binary needed.

---

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Options Reference](#options-reference)
- [Environment Variables](#environment-variables)
- [Recovery Flow](#recovery-flow)
  - [1 — Prerequisite Checks](#1--prerequisite-checks)
  - [2 — Prerequisite Restores](#2--prerequisite-restores-ordered)
  - [3 — Select Backup(s)](#3--select-backups)
  - [3a — Describe Backup / Filter Resources](#3a--describe-backup--filter-resource-types)
  - [4 — Select Namespaces](#4--select-namespaces)
  - [5 — Namespace Mapping](#5--namespace-mapping)
  - [6 — Review and Apply](#6--review-and-apply)
  - [7 — Wait and Validate](#7--wait-and-validate)
  - [8 — Repeat or Exit](#8--repeat-or-exit)
  - [9 — ArgoCD Summary](#9--argocd-summary)
- [Snapshot vs. File-System Backups](#snapshot-vs-file-system-backups)
- [Namespace Mapping (DR Namespaces)](#namespace-mapping-dr-namespaces)
- [Dry-Run Mode](#dry-run-mode)
- [Output Files](#output-files)
- [Prerequisite Restore Details](#prerequisite-restore-details)
  - [Step 1 — Namespaces / NetworkPolicies / EgressFirewalls](#step-1--namespaces--networkpolicies--egressfirewalls)
  - [Step 2 — DB2 StatefulSets + PVCs](#step-2--db2-statefulsets--pvcs)
  - [Step 3 — All-crds Workloads (WCM / MEP / EBA)](#step-3--all-crds-workloads-wcm--mep--eba)
  - [Step 5 — Sealed Secrets](#step-5--sealed-secrets)
  - [Step 6 — ArgoCD GitOps Backups](#step-6--argocd-gitops-backups)
  - [Step 7 — Patch ArgoCD Destinations](#step-7--patch-argocd-destinations)
- [Restore YAML Structure](#restore-yaml-structure)
- [Polling and Timeout](#polling-and-timeout)
- [Post-Restore Validation](#post-restore-validation)
- [ArgoCD Application Health Check](#argocd-application-health-check)
- [Non-Interactive / CI Mode](#non-interactive--ci-mode)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Tool      | Purpose |
|-----------|---------|
| `oc`      | All cluster interactions (apply, get, patch, exec) |
| `python3` | JSON parsing of Velero backup/restore status |
| Active `oc login` session | Must be logged in to the **DR / destination** cluster before starting |

---

## Quick Start

```bash
# 1. Log in to the DR cluster
oc login https://api.dr-cluster.example.com:6443 -u kubeadmin

# 2. Run the script interactively (recommended)
./oc-dr.sh

# 3. Or: list available backups first
./oc-dr.sh -l

# 4. Or: non-interactive single restore (CI/cron use)
./oc-dr.sh -b nightly-backup-20260721-060000 -n "billing,inventory"
```

---

## Usage

```
./oc-dr.sh                                    # Fully interactive (recommended for DR)
./oc-dr.sh -l                                 # List available Backup CRs and exit
./oc-dr.sh -b BACKUP_NAME -n "ns1,ns2"       # Direct restore of specific namespaces
./oc-dr.sh -b backup1,backup2                 # Restore multiple backups in sequence
./oc-dr.sh -b BACKUP_NAME --all-namespaces    # Restore all namespaces in the backup
./oc-dr.sh --dry-run                          # Render YAML only — never apply
./oc-dr.sh --non-interactive -b B -n "ns"     # CI/cron mode — no prompts
```

---

## Options Reference

| Flag | Default | Description |
|------|---------|-------------|
| `-b, --backup NAME[,NAME...]` | _(interactive)_ | Backup CR name(s) to restore from. Comma-separated for multiple. If omitted, an interactive menu is shown. |
| `-n, --namespaces LIST` | _(interactive)_ | Comma-separated namespaces to restore. If omitted, a per-backup menu is shown. |
| `--all-namespaces` | `false` | Restore all namespaces listed in the backup's `spec.includedNamespaces`. |
| `--velero-ns NAME` | `openshift-adp` | Namespace where OADP/Velero is installed. |
| `--restore-prefix NAME` | `dr-restore` | Prefix for generated Restore CR `metadata.name`. |
| `--exclude-resources LIST` | _(none)_ | Comma-separated resource types to exclude, e.g. `events,nodes`. |
| `--no-restore-pvs` | _(restorePVs: true)_ | Omit `restorePVs: true` from generated Restore CRs. |
| `--timeout SECONDS` | `1800` | Maximum seconds to wait per Restore CR before timing out. |
| `--poll-interval SECONDS` | `15` | Seconds between status polls while waiting for a restore to complete. |
| `--dry-run` | `false` | Render all Restore YAMLs and save to disk but **never** apply them. |
| `--non-interactive` | `false` | Never prompt; fail if required flags are missing. Use for CI/cron. |
| `-l, --list` | — | Print newest Backup CR per base name (name, phase, created, expires) and exit. |
| `-h, --help` | — | Show usage and exit. |

---

## Environment Variables

All flags can also be set as environment variables before running:

| Variable | Equivalent Flag |
|----------|----------------|
| `VELERO_NS` | `--velero-ns` |
| `NAMESPACES` | `-n` |
| `RESTORE_NAME_PREFIX` | `--restore-prefix` |
| `EXCLUDE_RESOURCES` | `--exclude-resources` |
| `POLL_INTERVAL` | `--poll-interval` |
| `RESTORE_TIMEOUT` | `--timeout` |
| `LOG_DIR` | _(output directory, default: `./dr-logs`)_ |
| `WAIT_FOR_APP_READY_TIMEOUT` | _(pod-ready wait, default: `300`s)_ |

---

## Recovery Flow

### 1 — Prerequisite Checks

Runs automatically before anything else:

- `oc` binary present and logged in (`oc whoami`)
- `python3` in PATH
- Velero namespace exists (`openshift-adp` or `--velero-ns`)
- `backups.velero.io` and `restores.velero.io` CRDs present
- At least one Velero pod running (label `app.kubernetes.io/name=velero`)
- All `BackupStorageLocations` are listed with name, phase, provider, and last sync time:

```
  NAME                                      PHASE         PROVIDER              LAST SYNC
  ----------------------------------------  ------------  --------------------  -------------------------
  dpa-1                                     Available     aws                   2026-07-24T07:01:00Z
```

A warning is printed if any BSL is not `Available` (source bucket not reachable).

### 2 — Prerequisite Restores (ordered)

Before any user-selected backup is restored, the script automatically discovers and prompts to restore foundational cluster resources in strict dependency order. See [Prerequisite Restore Details](#prerequisite-restore-details).

### 3 — Select Backup(s)

If `-b` was not given, the script shows a numbered menu of the **newest Backup CR per base name** (base name = name with trailing `-YYYYMMDD-HHMMSS` stripped). Columns shown:

```
#    BACKUP NAME                                                                STATUS         CREATED               EXPIRES
---  -----------------------------------------------------------------------   -------------  --------------------  --------------------
1    nightly-backup-20260721-060000                                            ✔ Completed    2026-07-21 06:00:00   2026-07-28 06:00:00
2    dr-full-20260720-180000                                                   ✔ Completed    2026-07-20 18:00:00   2026-07-27 18:00:00
```

Select by number, comma-separated numbers, or `all`.  
If a selected backup is not `Completed`, you are warned and asked to confirm before proceeding.

### 3a — Describe Backup / Filter Resource Types

After selecting a backup, you are asked:

```
Describe 'my-backup-20260721' to choose specific resource types? [y/N]:
```

If you answer `y`, the script executes `velero backup describe --details` inside the Velero pod (no local `velero` binary needed) and shows:

1. The full describe output
2. A numbered list of all resource kinds found in the backup

```
  #     RESOURCE KIND
  ---   ------------------------------
  1     Deployment
  2     ConfigMap
  3     Secret
  4     Service
  5     PersistentVolumeClaim
```

You then select which resource types to include:
- Enter or `all` → restore all (no `includedResources` filter)
- `1,3,5` → adds `includedResources: [Deployment, Secret, PersistentVolumeClaim]` to every Restore CR generated for this backup

If you answer `n`, all resource types are restored (default behaviour).

> The Velero binary is located automatically at `/velero` inside the pod (standard OADP path), with fallback to `$PATH`.

### 4 — Select Namespaces

For each selected backup, the script reads `spec.includedNamespaces` from the Backup CR and shows a numbered list. Select by number, `all`, or type a custom comma-separated list if the backup covers all namespaces (`*`).

### 5 — Namespace Mapping

Immediately after namespace selection for each backup, you are prompted **for every namespace** whether to restore to:

- **Option 1 — Original namespace**: generates `includedNamespaces: [ns]` in the Restore CR
- **Option 2 — New DR namespace**: generates `namespaceMapping: {ns: dr-ns}` in the Restore CR (and omits `includedNamespaces`)

Mappings are remembered for the session — each namespace is prompted only once (idempotent). This also applies to all prerequisite restores (DB2, WCM, Sealed Secrets, GitOps).

### 6 — Review and Apply

Before applying:

1. The script renders all Restore CRs as YAML and displays each inside a bordered box.
2. You are asked: **"Run recovery now? [y/N]"**
   - `y` → applies via `oc apply -f`
   - `n` → saves YAML to disk without applying (equivalent to `--dry-run` for this round)

### 7 — Wait and Validate

For each namespace:

1. **Polls** the Restore CR `status.phase` every `POLL_INTERVAL` seconds (default 15s):
   - `Completed` → success
   - `WaitingForPluginOperations` → CSI snapshot async operations still running, treated as success
   - `WaitingForPluginOperationsPartiallyFailed` → warning, prompt to continue
   - `PartiallyFailed` → warning, prompt to continue
   - `Failed` → error, prompt to continue or abort

2. **Post-restore validation** checks:
   - All pods `Running` and `Ready` (within `WAIT_FOR_APP_READY_TIMEOUT`, default 300s)
   - All PVCs in `Bound` state
   - All Routes `Admitted`

### 8 — Repeat or Exit

After each round completes, you are asked **"Restore another backup? [y/N]"** in interactive mode. The loop continues until you answer `n` or until all `-b`-specified backups are exhausted.

A final **summary table** is printed and saved showing result per backup/namespace:

```
==========================================
 DR Run Summary - 20260721-123456
==========================================
  nightly-backup-20260721/billing          RESTORE_OK
  nightly-backup-20260721/inventory        RESTORE_OK
  nightly-backup-20260721/auth             RESTORE_FAILED_OR_PARTIAL
==========================================
```

### 9 — ArgoCD Summary

At the end, the script lists all ArgoCD `Application` resources in `ose-gitops` and `ose-gitops-bd` with their `Sync` and `Health` status. Resources that are not `Synced + Healthy` are flagged with `⚠`.

---

## Snapshot vs. File-System Backups

The script auto-detects the backup type by reading the Backup CR:

| Condition | Backup type | Effect on Restore YAML |
|-----------|-------------|------------------------|
| `spec.defaultVolumesToRestic: false` **and** `spec.defaultVolumesToFsBackup: false` | **CSI / VolumeSnapshot** | `restorePVs:` is **omitted**; a comment is added explaining PVs will be restored from VolumeSnapshot |
| Any other combination | **File-system (Restic/Kopia)** | `restorePVs: true` is included |

This applies to: main restore loop, DB2 prereq, WCM Phase B (pvc-only prereq).

---

## Namespace Mapping (DR Namespaces)

When restoring to a DR cluster where namespaces have different names, use the interactive mapping prompt (Option 2) or provide mappings at the prompt for each namespace.

With namespace mapping active, the generated Restore YAML changes from:

```yaml
spec:
  includedNamespaces:
  - billing
```

to:

```yaml
spec:
  namespaceMapping:
    billing: billing-dr
```

`includedNamespaces` is always omitted when `namespaceMapping` is used.

---

## Dry-Run Mode

```bash
./oc-dr.sh --dry-run
```

- All Restore CR YAMLs are rendered and saved to `./dr-logs/restore-manifests-<timestamp>/`
- Nothing is applied to the cluster
- Useful for reviewing what would be restored before committing

---

## Output Files

All output is written to `./dr-logs/` (override with `LOG_DIR`):

| File / Directory | Contents |
|-----------------|---------|
| `dr-logs/dr-run-<timestamp>.log` | Timestamped log of all actions, warnings, and errors |
| `dr-logs/dr-summary-<timestamp>.txt` | Final summary table (backup/ns → result) |
| `dr-logs/restore-manifests-<timestamp>/` | All rendered Restore CR YAML files |
| `dr-logs/restore-manifests-<timestamp>/prereq-*.yaml` | Prerequisite restore YAMLs |
| `dr-logs/restore-manifests-<timestamp>/restore-<ns>.yaml` | Per-namespace restore YAMLs |

---

## Prerequisite Restore Details

Prerequisites run in strict order. Each is shown as a YAML box with an **"Apply prerequisite restore? [y/N]"** prompt before applying. All prerequisite namespaces also go through the [namespace mapping](#namespace-mapping-dr-namespaces) prompt.

### Step 1 — Namespaces / NetworkPolicies / EgressFirewalls

**Backup pattern**: `ose-infrastructure-backup-bankdata-resources-*`  
**Resources restored**: `Namespace`, `NetworkPolicy`, `EgressFirewall`  
**Namespaces**: `"*"` (all)

Must run first to ensure target namespaces exist before other restores try to write into them.

---

### Step 2 — DB2 StatefulSets + PVCs

**Backup pattern**: `db2u-velero-backup-*` (newest per base name)  
**Resources restored**: all (no `includedResources` filter)  
**Excluded**: `nodes`, `events`, CRD-managed Velero/CSI objects  
**PVs**: `restorePVs: true` (or snapshot comment if CSI backup)

If no matching backup is found, this step is silently skipped.

Multiple DB2 backups are discovered and shown in a numbered list — you select which to restore. All selected YAMLs are previewed before a single confirm prompt.

Namespace is auto-detected from `spec.includedNamespaces[0]` in the Backup CR (falls back to `ose-db2-bd`).

---

### Step 3 — All-crds Workloads (WCM / MEP / EBA)

**Backup patterns**:
- `dxo-velero-backup-all-crds-*` — discovers all, newest per base name
- `dxo-velero-backup-pvc-only-*` — matched to each all-crds backup by common infix

Restores are generated in **two phases per workload namespace**:

| Phase | Backup source | Resources | Purpose |
|-------|--------------|-----------|---------|
| **A** | `all-crds-*` | `ClusterRole`, `ServiceAccount` | RBAC must exist before PVCs are bound |
| **B** | `pvc-only-*` | All (no filter) | PVCs and workload state |

Excluded from all phases: `imagestreams`, `nodes`, `events`, CSI/Velero CRD objects.  
Phase B uses `restorePVs: true` (or snapshot comment).

All phase YAMLs are previewed in order before a single **"Apply all-crds/pvc-only restore(s) above (phases run in order A→B)?"** prompt. Phases run sequentially — each must complete before the next starts.

---

### Step 5 — Sealed Secrets

**Backup pattern**: `ose-infrastructure-backup-ose-sealed-secrets-*`  
**Namespace**: `ose-sealed-secrets`

Must be in place before ArgoCD reconciles and attempts to decrypt `SealedSecret` resources pulled from Git.

---

### Step 6 — ArgoCD GitOps Backups

**Backup pattern**: `*gitops*` (all backups containing "gitops", newest per base name)

The script discovers all matching backups and sorts them in dependency order:

| Priority | Pattern | Example |
|----------|---------|---------|
| 1 | `*openshift-gitops*` | `backup-openshift-gitops-20260721` |
| 2 | `*ose-gitops-hub*` | `ose-gitops-hub-20260721` |
| 3 | `*ose-gitops-ahx*` | `ose-gitops-ahx-20260721` |
| 4 | `*-bd*` variants | `ose-gitops-bd-20260721` |
| 5 | Everything else | `ose-gitops-xyz-20260721` |

**Resources restored per backup**: `AppProject`, `Application`, `Secret`

**Loop behaviour**: After each backup is restored, the remaining list is shown and you are asked **"Restore another gitops backup? [y/N]"**. This continues until all are restored or you stop.

**ArgoCD resource listing**: Before and after each gitops restore, the script lists all `AppProjects` and `Applications` in the effective namespace so you can compare.

---

### Step 7 — Patch ArgoCD Destinations

After all prereq restores, you are prompted:

```
Current cluster API server: https://api.dr-cluster.example.com:6443
Patch ArgoCD spec.destinations server URL? (needed when API URL differs from source cluster) [y/N]:
```

If you confirm:

1. The current DR cluster URL is auto-detected via `oc whoami --show-server`.
2. The old (source) cluster URL is auto-detected by scanning `spec.destination.server` across all ArgoCD `Application` resources in `ose-gitops` and `ose-gitops-bd`.
3. All `oc patch` commands that would be applied are shown for review.
4. A single **"Apply all N patch(es) above? [y/N]"** prompt applies the changes.

Both `Application` (`.spec.destination.server`) and `AppProject` (`.spec.destinations[*].server`) resources are patched.

> **Tip**: Use `spec.destinations.name` (cluster name) instead of `.server` (URL) in ArgoCD to avoid needing this patch permanently.

---

---

## Full Prereq Flow

```
run_prereq_restores()
│
├── STEP 1 ─ Namespaces / NetworkPolicies / EgressFirewalls
│   Pattern : ose-infrastructure-backup-bankdata-resources-*
│   Scope   : includedNamespaces: ["*"]  (all namespaces)
│   Resources: Namespace, NetworkPolicy, EgressFirewall
│   Mode    : inline — no user selection, auto-applied
│
├── STEP 2 ─ _restore_db2_prereq()
│   Pattern : db2u-velero-backup-*
│   │
│   ├─ List newest per base name
│   ├─ User selects: "1" / "1,2" / "all" / Enter=skip
│   ├─ For each selected:
│   │   ├─ Auto-detect namespace from Backup CR (fallback: ose-db2-bd)
│   │   ├─ prompt_ns_mapping_single (original or DR namespace)
│   │   ├─ Render YAML → prereq-db2-<ns>.yaml
│   │   │   excludedResources: nodes, events, backups, restores, …
│   │   │   restorePVs: auto-detected (snapshot vs file-system)
│   │   └─ _show_yaml_box → confirm → oc apply → wait_for_restore
│   └─ Continues even on PartiallyFailed (prompt)
│
├── STEP 3 ─ _restore_wcm_prereq()  [WCM / MEP / EBA / …]
│   Patterns: dxo-velero-backup-all-crds-*  +  dxo-velero-backup-pvc-only-*
│   │
│   ├─ List all-crds backups (newest per base)
│   ├─ User selects all-crds backup(s)
│   ├─ List pvc-only backups
│   ├─ User selects pvc-only backup(s) for Phase B (or skip)
│   │
│   ├─ For each selected all-crds backup:
│   │   ├─ Auto-detect namespace from Backup CR
│   │   ├─ prompt_ns_mapping_single
│   │   │
│   │   ├─ PHASE A → prereq-wcm-<ns>-a-sa.yaml
│   │   │   includedResources: ClusterRole, ServiceAccount only
│   │   │   (no PVCs — SAs must exist before PVCs are bound)
│   │   │
│   │   └─ PHASE B → prereq-wcm-<ns>-b-pvc.yaml
│   │       backupName: pvc-only backup
│   │       all resources except noise + restorePVs
│   │
│   ├─ Show ALL phase YAMLs before any prompt
│   ├─ Single confirm → apply ALL in strict A→B order
│   └─ Each phase waits for completion before next starts
│
├── STEP 5 ─ Sealed Secrets
│   Pattern : ose-infrastructure-backup-ose-sealed-secrets-*
│   Scope   : includedNamespaces: [ose-sealed-secrets]
│   Resources: all except noise (nodes, events, backups, …)
│   Mode    : inline — auto-finds newest, prompt_ns_mapping, _apply_prereq
│   ⚠ MUST complete before ArgoCD syncs (SealedSecrets need controller)
│
├── STEP 6+7 ─ _restore_gitops_prereq()  [loop]
│   Pattern : *gitops*  (all backups containing "gitops")
│   │
│   ├─ List newest per base name
│   ├─ Loop until user exits or all restored:
│   │   ├─ Show remaining backups
│   │   ├─ User selects
│   │   ├─ Sort by dependency order:
│   │   │   1. openshift-gitops  (platform ArgoCD)
│   │   │   2. ose-gitops-hub
│   │   │   3. ose-gitops-ahx
│   │   │   4. *-bd-* / *-bd    (bankdata ArgoCD)
│   │   │   5. everything else
│   │   │
│   │   └─ For each backup (in sorted order):
│   │       ├─ Auto-detect namespace from Backup CR
│   │       ├─ prompt_ns_mapping_single
│   │       ├─ Render YAML → prereq-gitops-<n>-<ns>.yaml
│   │       │   includedResources: AppProject, Application, Secret
│   │       ├─ _list_argocd_resources (BEFORE)   ← shows current state
│   │       ├─ _apply_prereq → oc apply → wait_for_restore
│   │       └─ _list_argocd_resources (AFTER)    ← shows restored state
│   └─ "Restore another gitops backup? [y/N]"
│
└── STEP 8 ─ patch_argocd_destinations()
    No backup — live cluster patching
    ├─ Discover all *gitops* namespaces
    ├─ Scan all Application + AppProject CRs
    ├─ For each with spec.destination.server pointing to source cluster:
    │   ├─ Show BEFORE box
    │   ├─ oc patch → new DR cluster API URL
    │   └─ Show AFTER box
    └─ Prompt to proceed per resource
```

### Key Design Rules

| Rule | Why |
|---|---|
| DB2 + WCM **before** ArgoCD | ArgoCD would recreate PVCs from scratch otherwise |
| Phase A (SAs) **before** Phase B (PVCs) | PVCs need ServiceAccounts to bind correctly |
| Sealed Secrets **before** GitOps | ArgoCD pulls SealedSecrets from Git — controller must exist |
| GitOps sorted (platform → hub → bd) | AppProjects must exist before Applications that reference them |
| Each `_apply_prereq` waits for completion | Next step cannot safely start on an in-flight restore |

## Restore YAML Structure

A typical generated Restore CR:

```yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: dr-restore-billing-20260721-123456
  namespace: openshift-adp
  labels:
    dr-script/run: "20260721-123456"
spec:
  backupName: nightly-backup-20260721-060000
  includedNamespaces:
  - billing
  restorePVs: true
```

With namespace mapping:

```yaml
spec:
  backupName: nightly-backup-20260721-060000
  namespaceMapping:
    billing: billing-dr
  restorePVs: true
```

With specific resource type filter (from backup describe selection):

```yaml
spec:
  backupName: nightly-backup-20260721-060000
  includedNamespaces:
  - billing
  restorePVs: true
  includedResources:
  - Deployment
  - Secret
  - PersistentVolumeClaim
```

For a CSI snapshot backup:

```yaml
spec:
  backupName: nightly-backup-20260721-060000
  includedNamespaces:
  - billing
  # snapshot backup (defaultVolumesToRestic/FsBackup=false)
  # restorePVs omitted — PVs will be restored from VolumeSnapshot
```

---

## Polling and Timeout

The script polls `status.phase` of each Restore CR every `POLL_INTERVAL` seconds (default: 15s):

| Phase | Action |
|-------|--------|
| `Completed` | ✅ Success — continue |
| `WaitingForPluginOperations` | ✅ CSI async ops in flight — treated as success |
| `WaitingForPluginOperationsPartiallyFailed` | ⚠ Warning — prompt to continue |
| `PartiallyFailed` | ⚠ Warning — prompt to continue |
| `Failed` | ❌ Error — prompt to continue or abort |
| `""` (CR not yet visible) | ℹ "Restore CR not yet found" — keep polling |
| `""` (CR exists, no phase yet) | ℹ "CR exists, status.phase not yet set" — keep polling |
| oc command error (rc≠0) | ⚠ Warning with rc and namespace shown |

Timeout (default: `1800`s / 30 min). Override with `--timeout SECONDS`.

---

## Post-Restore Validation

After each successful restore, the script validates the target namespace:

1. **Pods** — waits up to `WAIT_FOR_APP_READY_TIMEOUT` (default 300s) for all pods to be `Running` and fully ready (`ready/total`)
2. **PVCs** — lists any PVCs not in `Bound` state
3. **Routes** — checks all Routes have at least one `Admitted` ingress condition

Warnings are printed and logged but do not abort the script.

---

## ArgoCD Application Health Check

At the very end of the script run, a table is printed for all ArgoCD `Application` CRs in `ose-gitops` and `ose-gitops-bd`:

```
  NAME                                               SYNC            HEALTH
  -------------------------------------------------- --------------- ----------
  billing-app                                        Synced          Healthy
  inventory-app                                      OutOfSync       Degraded ⚠
```

Resources not `Synced + Healthy` are flagged with `⚠`.

---

## Non-Interactive / CI Mode

```bash
./oc-dr.sh --non-interactive -b nightly-backup-20260721-060000 -n "billing,inventory"
```

- Never prompts — fails immediately if required info is missing
- Namespace mappings default to original namespace (no DR remapping)
- Applies all restores without confirmation
- Suitable for cron jobs and CI pipelines

---

## Troubleshooting

### `BackupStorageLocation NOT Available`

The source bucket is not reachable from the DR cluster. Verify:
- The OADP `DataProtectionApplication` BSL credentials point to the correct bucket/region
- The bucket exists and contains the source cluster's backup objects
- Network/firewall allows the Velero pod to reach object storage

### `Restore CR not yet found` keeps looping

The `oc apply` succeeded but Velero hasn't created the Restore CR yet, or the name/namespace is wrong. Check:
```bash
oc get restores.velero.io -n openshift-adp
oc describe restores.velero.io <restore-name> -n openshift-adp
```

### `oc get failed (rc=1)` while polling

The `oc` session may have expired, or the `--velero-ns` is incorrect. Verify:
```bash
oc whoami
oc get ns openshift-adp
```

### Restore is `PartiallyFailed`

Some resources could not be restored (often pre-existing resources that Velero skips by default). Review:
```bash
oc describe restores.velero.io <restore-name> -n openshift-adp
```
Consider setting `existingResourcePolicy: update` in the Restore spec if you need to overwrite existing resources.

### Backup describe shows no resource types

The Velero pod may not have the binary at the expected path (`/velero`). The script auto-detects and falls back to `$PATH`. If it still fails, the actual error is shown and all resource types are restored (safe default).

### ArgoCD apps stuck `OutOfSync` after restore

1. Verify ArgoCD destination server URL is correct (use [Step 7 — Patch ArgoCD Destinations](#step-7--patch-argocd-destinations))
2. Verify `SealedSecrets` were restored before ArgoCD started reconciling
3. Check ArgoCD application controller logs:
   ```bash
   oc logs -n ose-gitops deployment/openshift-gitops-application-controller
   ```

### `python3` not found

Install Python 3 or ensure it is in `PATH`. On RHEL/OpenShift bastion hosts:
```bash
sudo dnf install python3
```

---

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Options Reference](#options-reference)
- [Environment Variables](#environment-variables)
- [Recovery Flow](#recovery-flow)
  - [1 — Prerequisite Checks](#1--prerequisite-checks)
  - [2 — Prerequisite Restores](#2--prerequisite-restores-ordered)
  - [3 — Select Backup(s)](#3--select-backups)
  - [4 — Select Namespaces](#4--select-namespaces)
  - [5 — Namespace Mapping](#5--namespace-mapping)
  - [6 — Review and Apply](#6--review-and-apply)
  - [7 — Wait and Validate](#7--wait-and-validate)
  - [8 — Repeat or Exit](#8--repeat-or-exit)
  - [9 — ArgoCD Summary](#9--argocd-summary)
- [Snapshot vs. File-System Backups](#snapshot-vs-file-system-backups)
- [Namespace Mapping (DR Namespaces)](#namespace-mapping-dr-namespaces)
- [Dry-Run Mode](#dry-run-mode)
- [Output Files](#output-files)
- [Prerequisite Restore Details](#prerequisite-restore-details)
  - [Step 1 — Namespaces / NetworkPolicies / EgressFirewalls](#step-1--namespaces--networkpolicies--egressfirewalls)
  - [Step 2 — DB2 StatefulSets + PVCs](#step-2--db2-statefulsets--pvcs)
  - [Step 3 — All-crds Workloads (WCM / MEP / EBA)](#step-3--all-crds-workloads-wcm--mep--eba)
  - [Step 5 — Sealed Secrets](#step-5--sealed-secrets)
  - [Step 6 — ArgoCD GitOps Backups](#step-6--argocd-gitops-backups)
  - [Step 7 — Patch ArgoCD Destinations](#step-7--patch-argocd-destinations)
- [Restore YAML Structure](#restore-yaml-structure)
- [Polling and Timeout](#polling-and-timeout)
- [Post-Restore Validation](#post-restore-validation)
- [ArgoCD Application Health Check](#argocd-application-health-check)
- [Non-Interactive / CI Mode](#non-interactive--ci-mode)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Tool      | Purpose |
|-----------|---------|
| `oc`      | All cluster interactions (apply, get, patch, describe) |
| `python3` | JSON parsing of Velero backup/restore status |
| Active `oc login` session | Must be logged in to the **DR / destination** cluster before starting |

---

## Quick Start

```bash
# 1. Log in to the DR cluster
oc login https://api.dr-cluster.example.com:6443 -u kubeadmin

# 2. Run the script interactively (recommended)
./oc-dr.sh

# 3. Or: list available backups first
./oc-dr.sh -l

# 4. Or: non-interactive single restore (CI/cron use)
./oc-dr.sh -b nightly-backup-20260721-060000 -n "billing,inventory"
```

---

## Usage

```
./oc-dr.sh                                    # Fully interactive (recommended for DR)
./oc-dr.sh -l                                 # List available Backup CRs and exit
./oc-dr.sh -b BACKUP_NAME -n "ns1,ns2"       # Direct restore of specific namespaces
./oc-dr.sh -b backup1,backup2                 # Restore multiple backups in sequence
./oc-dr.sh -b BACKUP_NAME --all-namespaces    # Restore all namespaces in the backup
./oc-dr.sh --dry-run                          # Render YAML only — never apply
./oc-dr.sh --non-interactive -b B -n "ns"     # CI/cron mode — no prompts
```

---

## Options Reference

| Flag | Default | Description |
|------|---------|-------------|
| `-b, --backup NAME[,NAME...]` | _(interactive)_ | Backup CR name(s) to restore from. Comma-separated for multiple. If omitted, an interactive menu is shown. |
| `-n, --namespaces LIST` | _(interactive)_ | Comma-separated namespaces to restore. If omitted, a per-backup menu is shown. |
| `--all-namespaces` | `false` | Restore all namespaces listed in the backup's `spec.includedNamespaces`. |
| `--velero-ns NAME` | `openshift-adp` | Namespace where OADP/Velero is installed. |
| `--restore-prefix NAME` | `dr-restore` | Prefix for generated Restore CR `metadata.name`. |
| `--exclude-resources LIST` | _(none)_ | Comma-separated resource types to exclude, e.g. `events,nodes`. |
| `--no-restore-pvs` | _(restorePVs: true)_ | Omit `restorePVs: true` from generated Restore CRs. |
| `--timeout SECONDS` | `1800` | Maximum seconds to wait per Restore CR before timing out. |
| `--poll-interval SECONDS` | `15` | Seconds between status polls while waiting for a restore to complete. |
| `--dry-run` | `false` | Render all Restore YAMLs and save to disk but **never** apply them. |
| `--non-interactive` | `false` | Never prompt; fail if required flags are missing. Use for CI/cron. |
| `-l, --list` | — | Print newest Backup CR per base name (name, phase, created, expires) and exit. |
| `-h, --help` | — | Show usage and exit. |

---

## Environment Variables

All flags can also be set as environment variables before running:

| Variable | Equivalent Flag |
|----------|----------------|
| `VELERO_NS` | `--velero-ns` |
| `NAMESPACES` | `-n` |
| `RESTORE_NAME_PREFIX` | `--restore-prefix` |
| `EXCLUDE_RESOURCES` | `--exclude-resources` |
| `POLL_INTERVAL` | `--poll-interval` |
| `RESTORE_TIMEOUT` | `--timeout` |
| `LOG_DIR` | _(output directory, default: `./dr-logs`)_ |
| `WAIT_FOR_APP_READY_TIMEOUT` | _(pod-ready wait, default: `300`s)_ |

---

## Recovery Flow

### 1 — Prerequisite Checks

Runs automatically before anything else:

- `oc` binary present and logged in (`oc whoami`)
- `python3` in PATH
- Velero namespace exists (`openshift-adp` or `--velero-ns`)
- `backups.velero.io` and `restores.velero.io` CRDs present
- At least one Velero pod running (label `app.kubernetes.io/name=velero`)
- All `BackupStorageLocations` are in `Available` phase — warns if not (source bucket not reachable)

### 2 — Prerequisite Restores (ordered)

Before any user-selected backup is restored, the script automatically discovers and prompts to restore foundational cluster resources in strict dependency order. See [Prerequisite Restore Details](#prerequisite-restore-details).

### 3 — Select Backup(s)

If `-b` was not given, the script shows a numbered menu of the **newest Backup CR per base name** (base name = name with trailing `-YYYYMMDD-HHMMSS` stripped). Columns shown:

```
#    BACKUP NAME                              STATUS         CREATED               EXPIRES
---  ---------------------------------------  -------------  --------------------  --------------------
1    nightly-backup-20260721-060000           ✔ Completed    2026-07-21 06:00:00   2026-07-28 06:00:00
2    dr-full-20260720-180000                  ✔ Completed    2026-07-20 18:00:00   2026-07-27 18:00:00
```

Select by number, comma-separated numbers, or `all`.  
If a selected backup is not `Completed`, you are warned and asked to confirm before proceeding.

### 4 — Select Namespaces

For each selected backup, the script reads `spec.includedNamespaces` from the Backup CR and shows a numbered list. Select by number, `all`, or type a custom comma-separated list if the backup covers all namespaces (`*`).

### 5 — Namespace Mapping

Immediately after namespace selection for each backup, you are prompted **for every namespace** whether to restore to:

- **Option 1 — Original namespace**: generates `includedNamespaces: [ns]` in the Restore CR
- **Option 2 — New DR namespace**: generates `namespaceMapping: {ns: dr-ns}` in the Restore CR (and omits `includedNamespaces`)

Mappings are remembered for the session — each namespace is prompted only once (idempotent). This also applies to all prerequisite restores (DB2, WCM, Sealed Secrets, GitOps).

### 6 — Review and Apply

Before applying:

1. The script renders all Restore CRs as YAML and displays each inside a bordered box.
2. You are asked: **"Run recovery now? [y/N]"**
   - `y` → applies via `oc apply -f`
   - `n` → saves YAML to disk without applying (equivalent to `--dry-run` for this round)

### 7 — Wait and Validate

For each namespace:

1. **Polls** the Restore CR `status.phase` every `POLL_INTERVAL` seconds (default 15s):
   - `Completed` → success
   - `WaitingForPluginOperations` → CSI snapshot async operations still running, treated as success
   - `WaitingForPluginOperationsPartiallyFailed` → warning, prompt to continue
   - `PartiallyFailed` → warning, prompt to continue
   - `Failed` → error, prompt to continue or abort

2. **Post-restore validation** checks:
   - All pods `Running` and `Ready` (within `WAIT_FOR_APP_READY_TIMEOUT`, default 300s)
   - All PVCs in `Bound` state
   - All Routes `Admitted`

### 8 — Repeat or Exit

After each round completes, you are asked **"Restore another backup? [y/N]"** in interactive mode. The loop continues until you answer `n` or until all `-b`-specified backups are exhausted.

A final **summary table** is printed and saved showing result per backup/namespace:

```
==========================================
 DR Run Summary - 20260721-123456
==========================================
  nightly-backup-20260721/billing          RESTORE_OK
  nightly-backup-20260721/inventory        RESTORE_OK
  nightly-backup-20260721/auth             RESTORE_FAILED_OR_PARTIAL
==========================================
```

### 9 — ArgoCD Summary

At the end, the script lists all ArgoCD `Application` resources in `ose-gitops` and `ose-gitops-bd` with their `Sync` and `Health` status. Resources that are not `Synced + Healthy` are flagged with `⚠`.

---

## Snapshot vs. File-System Backups

The script auto-detects the backup type by reading the Backup CR:

| Condition | Backup type | Effect on Restore YAML |
|-----------|-------------|------------------------|
| `spec.defaultVolumesToRestic: false` **and** `spec.defaultVolumesToFsBackup: false` | **CSI / VolumeSnapshot** | `restorePVs:` is **omitted**; a comment is added explaining PVs will be restored from VolumeSnapshot |
| Any other combination | **File-system (Restic/Kopia)** | `restorePVs: true` is included |

This applies to: main restore loop, DB2 prereq, WCM Phase B (pvc-only prereq).

---

## Namespace Mapping (DR Namespaces)

When restoring to a DR cluster where namespaces have different names, use the interactive mapping prompt (Option 2) or provide mappings at the prompt for each namespace.

With namespace mapping active, the generated Restore YAML changes from:

```yaml
spec:
  includedNamespaces:
  - billing
```

to:

```yaml
spec:
  namespaceMapping:
    billing: billing-dr
```

`includedNamespaces` is always omitted when `namespaceMapping` is used.

---

## Dry-Run Mode

```bash
./oc-dr.sh --dry-run
```

- All Restore CR YAMLs are rendered and saved to `./dr-logs/restore-manifests-<timestamp>/`
- Nothing is applied to the cluster
- Useful for reviewing what would be restored before committing

---

## Output Files

All output is written to `./dr-logs/` (override with `LOG_DIR`):

| File / Directory | Contents |
|-----------------|---------|
| `dr-logs/dr-run-<timestamp>.log` | Timestamped log of all actions, warnings, and errors |
| `dr-logs/dr-summary-<timestamp>.txt` | Final summary table (backup/ns → result) |
| `dr-logs/restore-manifests-<timestamp>/` | All rendered Restore CR YAML files |
| `dr-logs/restore-manifests-<timestamp>/prereq-*.yaml` | Prerequisite restore YAMLs |
| `dr-logs/restore-manifests-<timestamp>/restore-<ns>.yaml` | Per-namespace restore YAMLs |

---

## Prerequisite Restore Details

Prerequisites run in strict order. Each is shown as a YAML box with an **"Apply prerequisite restore? [y/N]"** prompt before applying. All prerequisite namespaces also go through the [namespace mapping](#namespace-mapping-dr-namespaces) prompt.

### Step 1 — Namespaces / NetworkPolicies / EgressFirewalls

**Backup pattern**: `ose-infrastructure-backup-bankdata-resources-*`  
**Resources restored**: `Namespace`, `NetworkPolicy`, `EgressFirewall`  
**Namespaces**: `"*"` (all)

Must run first to ensure target namespaces exist before other restores try to write into them.

---

### Step 2 — DB2 StatefulSets + PVCs

**Backup pattern**: `db2u-velero-backup-*` (newest per base name)  
**Resources restored**: all (no `includedResources` filter)  
**Excluded**: `nodes`, `events`, CRD-managed Velero/CSI objects  
**PVs**: `restorePVs: true` (or snapshot comment if CSI backup)

If no matching backup is found, this step is silently skipped.

Multiple DB2 backups are discovered and shown in a numbered list — you select which to restore. All selected YAMLs are previewed before a single confirm prompt.

Namespace is auto-detected from `spec.includedNamespaces[0]` in the Backup CR (falls back to `ose-db2-bd`).

---

### Step 3 — All-crds Workloads (WCM / MEP / EBA)

**Backup patterns**:
- `dxo-velero-backup-all-crds-*` — discovers all, newest per base name
- `dxo-velero-backup-pvc-only-*` — matched to each all-crds backup by common infix

Restores are generated in **two phases per workload namespace**:

| Phase | Backup source | Resources | Purpose |
|-------|--------------|-----------|---------|
| **A** | `all-crds-*` | `ClusterRole`, `ServiceAccount` | RBAC must exist before PVCs are bound |
| **B** | `pvc-only-*` | All (no filter) | PVCs and workload state |

Excluded from all phases: `imagestreams`, `nodes`, `events`, CSI/Velero CRD objects.  
Phase B uses `restorePVs: true` (or snapshot comment).

All phase YAMLs are previewed in order before a single **"Apply all-crds/pvc-only restore(s) above (phases run in order A→B)?"** prompt. Phases run sequentially — each must complete before the next starts.

---

### Step 5 — Sealed Secrets

**Backup pattern**: `ose-infrastructure-backup-ose-sealed-secrets-*`  
**Namespace**: `ose-sealed-secrets`

Must be in place before ArgoCD reconciles and attempts to decrypt `SealedSecret` resources pulled from Git.

---

### Step 6 — ArgoCD GitOps Backups

**Backup pattern**: `*gitops*` (all backups containing "gitops", newest per base name)

The script discovers all matching backups and sorts them in dependency order:

| Priority | Pattern | Example |
|----------|---------|---------|
| 1 | `*openshift-gitops*` | `backup-openshift-gitops-20260721` |
| 2 | `*ose-gitops-hub*` | `ose-gitops-hub-20260721` |
| 3 | `*ose-gitops-ahx*` | `ose-gitops-ahx-20260721` |
| 4 | `*-bd*` variants | `ose-gitops-bd-20260721` |
| 5 | Everything else | `ose-gitops-xyz-20260721` |
| Last | Plain `*ose-gitops*` (catch-all) | `ose-gitops-20260721` |

**Resources restored per backup**: `AppProject`, `Application` only.

**Loop behaviour**: After each backup is restored, the remaining list is shown and you are asked **"Restore another gitops backup? [y/N]"**. This continues until all are restored or you stop.

**ArgoCD resource listing**: Before and after each gitops restore, the script lists all `AppProjects` and `Applications` in the effective namespace so you can compare.

---

### Step 7 — Patch ArgoCD Destinations

After all prereq restores, you are prompted:

```
Current cluster API server: https://api.dr-cluster.example.com:6443
Patch ArgoCD spec.destinations server URL? (needed when API URL differs from source cluster) [y/N]:
```

If you confirm:

1. The current DR cluster URL is auto-detected via `oc whoami --show-server`.
2. The old (source) cluster URL is auto-detected by scanning `spec.destination.server` across all ArgoCD `Application` resources in `ose-gitops` and `ose-gitops-bd`.
3. All `oc patch` commands that would be applied are shown for review.
4. A single **"Apply all N patch(es) above? [y/N]"** prompt applies the changes.

Both `Application` (`.spec.destination.server`) and `AppProject` (`.spec.destinations[*].server`) resources are patched.

> **Tip**: Use `spec.destinations.name` (cluster name) instead of `.server` (URL) in ArgoCD to avoid needing this patch permanently.

---

## Restore YAML Structure

A typical generated Restore CR:

```yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: dr-restore-billing-20260721-123456
  namespace: openshift-adp
  labels:
    dr-script/run: "20260721-123456"
spec:
  backupName: nightly-backup-20260721-060000
  includedNamespaces:
  - billing
  restorePVs: true
```

With namespace mapping:

```yaml
spec:
  backupName: nightly-backup-20260721-060000
  namespaceMapping:
    billing: billing-dr
  restorePVs: true
```

For a CSI snapshot backup:

```yaml
spec:
  backupName: nightly-backup-20260721-060000
  includedNamespaces:
  - billing
  # snapshot backup (defaultVolumesToRestic/FsBackup=false)
  # restorePVs omitted — PVs will be restored from VolumeSnapshot
```

---

## Polling and Timeout

The script polls `status.phase` of each Restore CR every `POLL_INTERVAL` seconds (default: 15s):

| Phase | Action |
|-------|--------|
| `Completed` | ✅ Success — continue |
| `WaitingForPluginOperations` | ✅ CSI async ops in flight — treated as success |
| `WaitingForPluginOperationsPartiallyFailed` | ⚠ Warning — prompt to continue |
| `PartiallyFailed` | ⚠ Warning — prompt to continue |
| `Failed` | ❌ Error — prompt to continue or abort |
| `""` (CR not yet visible) | ℹ "Restore CR not yet found" — keep polling |
| `""` (CR exists, no phase yet) | ℹ "CR exists, status.phase not yet set" — keep polling |
| oc command error (rc≠0) | ⚠ Warning with rc and namespace shown |

Timeout (default: `1800`s / 30 min). Override with `--timeout SECONDS`.

---

## Post-Restore Validation

After each successful restore, the script validates the target namespace:

1. **Pods** — waits up to `WAIT_FOR_APP_READY_TIMEOUT` (default 300s) for all pods to be `Running` and fully ready (`ready/total`)
2. **PVCs** — lists any PVCs not in `Bound` state
3. **Routes** — checks all Routes have at least one `Admitted` ingress condition

Warnings are printed and logged but do not abort the script.

---

## ArgoCD Application Health Check

At the very end of the script run, a table is printed for all ArgoCD `Application` CRs in `ose-gitops` and `ose-gitops-bd`:

```
  NAME                                               SYNC            HEALTH
  -------------------------------------------------- --------------- ----------
  billing-app                                        Synced          Healthy
  inventory-app                                      OutOfSync       Degraded ⚠
```

Resources not `Synced + Healthy` are flagged with `⚠`.

---

## Non-Interactive / CI Mode

```bash
./oc-dr.sh --non-interactive -b nightly-backup-20260721-060000 -n "billing,inventory"
```

- Never prompts — fails immediately if required info is missing
- Namespace mappings default to original namespace (no DR remapping)
- Applies all restores without confirmation
- Suitable for cron jobs and CI pipelines

---

## Troubleshooting

### `BackupStorageLocation NOT Available`

The source bucket is not reachable from the DR cluster. Verify:
- The OADP `DataProtectionApplication` BSL credentials point to the correct bucket/region
- The bucket exists and contains the source cluster's backup objects
- Network/firewall allows the Velero pod to reach object storage

### `Restore CR not yet found` keeps looping

The `oc apply` succeeded but Velero hasn't created the Restore CR yet, or the name/namespace is wrong. Check:
```bash
oc get restores.velero.io -n openshift-adp
oc describe restores.velero.io <restore-name> -n openshift-adp
```

### `oc get failed (rc=1)` while polling

The `oc` session may have expired, or the `--velero-ns` is incorrect. Verify:
```bash
oc whoami
oc get ns openshift-adp
```

### Restore is `PartiallyFailed`

Some resources could not be restored (often pre-existing resources that Velero skips by default). Review:
```bash
oc describe restores.velero.io <restore-name> -n openshift-adp
```
Consider setting `existingResourcePolicy: update` in the Restore spec if you need to overwrite existing resources.

### ArgoCD apps stuck `OutOfSync` after restore

1. Verify ArgoCD destination server URL is correct (use [Step 7 — Patch ArgoCD Destinations](#step-7--patch-argocd-destinations))
2. Verify `SealedSecrets` were restored before ArgoCD started reconciling
3. Check ArgoCD application controller logs:
   ```bash
   oc logs -n ose-gitops deployment/openshift-gitops-application-controller
   ```

### `python3` not found

Install Python 3 or ensure it is in `PATH`. On RHEL/OpenShift bastion hosts:
```bash
sudo dnf install python3
```

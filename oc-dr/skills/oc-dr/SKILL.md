---
name: oc-dr
description: >
  OpenShift Disaster Recovery assistant using Velero / OADP. Invoke when working
  with oc-dr.sh, writing Restore CRs, debugging failed restores, adding prerequisite
  restore steps, or modifying the DR script. Provides script structure knowledge,
  Restore YAML patterns, troubleshooting commands, and oc/velero reference patterns.
---

# oc-dr — OpenShift Disaster Recovery Skill

Context and reference knowledge for `oc-dr.sh` — an interactive bash DR script for OpenShift using Velero / OADP.

- **Script**: `/Users/jsk/copilot-dir/DR/oc-dr.sh`
- **Docs**:   `/Users/jsk/copilot-dir/DR/ose-dr-readme.md`

---

---

## Full Prereq Flow

All steps run in strict dependency order inside `run_prereq_restores()`. **ORDER MATTERS** — do not skip or reorder steps.

---

### STEP 1 — Namespaces / NetworkPolicies / EgressFirewalls

- **Backup pattern**: `ose-infrastructure-backup-bankdata-resources-*`
- **Scope**: `includedNamespaces: ["*"]` (all namespaces)
- **Resources**: `Namespace`, `NetworkPolicy`, `EgressFirewall`
- **Mode**: inline — no user selection, auto-applied immediately

---

### STEP 2 — DB2 (`_restore_db2_prereq`)

- **Backup pattern**: `db2u-velero-backup-*`
- **User interaction**: numbered menu — enter `1`, `1,2`, `all`, or press Enter to skip
- **Per selected backup**:
  1. Auto-detect namespace from Backup CR (fallback: `ose-db2-bd`)
  2. `prompt_ns_mapping_single` — original or DR namespace
  3. Render YAML → `prereq-db2-<ns>.yaml`
     - `excludedResources`: nodes, events, backups, restores, …
     - `restorePVs`: auto-detected (snapshot vs file-system)
  4. Show YAML box → confirm → `oc apply` → `wait_for_restore`
- Continues even on `PartiallyFailed` (user prompted)

---

### STEP 3 — WCM / MEP / EBA (`_restore_wcm_prereq`)

- **Backup patterns**: `dxo-velero-backup-all-crds-*` + `dxo-velero-backup-pvc-only-*`
- **User interaction**: select all-crds backup(s), then optionally select pvc-only backup(s) for Phase B
- **Per selected all-crds backup**:
  1. Auto-detect namespace from Backup CR
  2. `prompt_ns_mapping_single`
  3. **Phase A** → `prereq-wcm-<ns>-a-sa.yaml`
     - `includedResources`: `ClusterRole`, `ServiceAccount` only
     - SAs must exist before PVCs are bound
  4. **Phase B** → `prereq-wcm-<ns>-b-pvc.yaml`
     - `backupName`: pvc-only backup
     - All resources except noise + `restorePVs`
- All phase YAMLs shown before any prompt
- Single confirm → apply ALL in strict A → B order
- Each phase waits for completion before next starts

---

### STEP 5 — Sealed Secrets

- **Backup pattern**: `ose-infrastructure-backup-ose-sealed-secrets-*`
- **Scope**: `includedNamespaces: [ose-sealed-secrets]`
- **Resources**: all except noise (nodes, events, backups, …)
- **Mode**: inline — auto-finds newest, `prompt_ns_mapping`, `_apply_prereq`
- ⚠️ **Must complete before ArgoCD syncs** — SealedSecrets controller must exist first

---

### STEP 6+7 — GitOps / ArgoCD (`_restore_gitops_prereq`)

- **Backup pattern**: `*gitops*` (all backups containing "gitops")
- **User interaction**: loop — select backups, restore, then prompted to restore more
- **Dependency sort order** (applied automatically):
  1. `openshift-gitops` — platform ArgoCD
  2. `ose-gitops-hub`
  3. `ose-gitops-ahx`
  4. `*-bd-*` / `*-bd` — Bankdata ArgoCD
  5. everything else
- **Per backup (in sorted order)**:
  1. Auto-detect namespace from Backup CR
  2. `prompt_ns_mapping_single`
  3. Render YAML → `prereq-gitops-<n>-<ns>.yaml`
     - `includedResources`: `AppProject`, `Application`, `Secret`
  4. `_list_argocd_resources` (BEFORE) — shows current state
  5. `_apply_prereq` → `oc apply` → `wait_for_restore`
  6. `_list_argocd_resources` (AFTER) — shows restored state
- Ends with prompt: `"Restore another gitops backup? [y/N]"`

---

### STEP 8 — Patch ArgoCD Destinations (`patch_argocd_destinations`)

- **No backup** — live cluster patching only
- Discovers all `*gitops*` namespaces
- Scans all `Application` + `AppProject` CRs
- For each resource where `spec.destination.server` points to the **source** cluster:
  1. Show BEFORE box
  2. `oc patch` → new DR cluster API URL
  3. Show AFTER box
  4. Prompt to proceed per resource

### Key Design Rules

| Rule | Why |
|---|---|
| DB2 + WCM **before** ArgoCD | ArgoCD would recreate PVCs from scratch otherwise |
| Phase A (SAs) **before** Phase B (PVCs) | PVCs need ServiceAccounts to bind correctly |
| Sealed Secrets **before** GitOps | ArgoCD pulls SealedSecrets from Git — controller must exist |
| GitOps sorted (platform → hub → bd) | AppProjects must exist before Applications that reference them |
| Each `_apply_prereq` waits for completion | Next step cannot safely start on an in-flight restore |


---


## Script Architecture

### Key global variables
```bash
VELERO_NS="openshift-adp"
BACKUP_CRD="backups.velero.io"
RESTORE_CRD="restores.velero.io"
BACKUP_NAMES=()                    # multi-backup selection array
NS_MAPPING_ORIG=()                 # parallel arrays for namespace mapping
NS_MAPPING_TARGET=()
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="./dr-logs"
YAML_DIR="${LOG_DIR}/restore-manifests-${TIMESTAMP}"
```

### Full function map
| Line | Function | Purpose |
|---|---|---|
| 73 | `error` | Print error and exit 1 |
| 76 | `die` | Alias for error |
| 81 | `usage` | Print usage/help and exit |
| 147 | `check_prereqs` | oc login, python3, OADP CRDs, Velero pod, BSL status table |
| 211 | `list_backups` | `-l` flag: print newest per base name and exit |
| 239 | `select_backup_interactive` | Numbered menu, supports `1`, `1,3`, `all` |
| 343 | `validate_backup` | Checks backup phase (Completed / PartiallyFailed / other) |
| 363 | `get_backup_included_namespaces` | Reads `spec.includedNamespaces` from Backup CR |
| 376 | `select_namespaces_interactive` | Namespace picker per backup |
| 426 | `resolve_namespaces` | Resolves namespace list from flags or interactive selection |
| 443 | `get_ns_mapping NS` | Returns DR target ns for NS, or `""` if original |
| 452 | `_ns_mapping_recorded NS` | Returns 0 if NS already prompted (idempotent) |
| 462 | `prompt_ns_mapping_single NS` | Interactive: original ns or DR mapped ns (once per ns) |
| 490 | `append_ns_mapping_to_yaml FILE NS` | Rewrites YAML: swaps `includedNamespaces` → `namespaceMapping` |
| 507 | `prompt_namespace_mapping NS_LIST` | Calls `prompt_ns_mapping_single` for each ns in CSV list |
| 518 | `pre_restore_check NS` | Warns if ns already exists with resources |
| 534 | `_is_snapshot_backup BACKUP` | Returns 0 if CSI snapshot backup (no Restic/Kopia) |
| 545 | `_restorePVs_yaml_line BACKUP` | Emits `restorePVs: true` or snapshot comment |
| 559 | `_play_dr_animation` | Startup: looping 5-frame DR scenario (healthy→fault→down→failover→recovered), stops on Enter |
| 680 | `_velero_describe_backup BACKUP` | Execs into Velero pod, runs `velero backup describe --details` |
| 712 | `_velero_describe_restore NAME` | Execs into Velero pod, runs `velero restore describe --details` after restore completes; shows restored/skipped counts |
| 762 | `select_included_resources_interactive` | Parses backup describe output, numbered resource type picker, sets `INCLUDE_RESOURCES` global |
| 863 | `render_restore_yaml NS NAME FILE TARGET_NS` | Writes Restore CR YAML (with mapping if target_ns set, with `includedResources` if set) |
| 907 | `create_restore NS` | render + dry-run print or `oc apply` |
| 937 | `wait_for_restore NAME` | Polls `status.phase` with elapsed timer, handles all phases, calls `_velero_describe_restore` on terminal phase |
| 1009 | `validate_namespace NS` | Checks pods/PVCs/routes post-restore |
| 1072 | `_apply_prereq FILE NAME DESC` | Show box → prompt → apply → wait → handle rc |
| 1125 | `_find_newest_backup PREFIX` | Newest backup matching `^PREFIX-\d` |
| 1143 | `_find_newest_backup_containing STR` | Newest backup whose name contains STR |
| 1160 | `_list_backups_matching STR` | All backup names containing STR |
| 1177 | `_list_newest_per_base_matching STR` | Newest per base name among backups containing STR |
| 1201 | `_show_yaml_box FILE` | Prints YAML inside a `┌─┐` border box |
| 1214 | `_restore_db2_prereq` | Lists `db2u-velero-backup-*`, user selects, pre-renders + applies |
| 1352 | `_restore_wcm_prereq` | Lists `dxo-velero-backup-all-crds-*` + `pvc-only-*`, Phase A→B |
| 1573 | `_list_argocd_resources NS LABEL` | Lists AppProjects, Applications, and ArgoCD secrets (`argocd.argoproj.io/secret-type`) with decoded data (sensitive fields masked) |
| 1657 | `_restore_gitops_prereq` | Loop over all `*gitops*` backups in dependency order |
| 1800 | `run_prereq_restores` | Orchestrates all prereq steps 1–8 in order |
| 1884 | `patch_argocd_destinations` | Discover `*gitops*` namespaces, loop: scan apps, patch `spec.destination.server` to DR cluster URL, show BEFORE/AFTER |
| 2152 | `_patch_argocd_resource KIND NAME NS OLD NEW` | Shows BEFORE box → patch → AFTER box for one ArgoCD resource |
| 2212 | `check_argocd_apps` | Final summary: lists Sync/Health of all ArgoCD apps |
| 2249 | `main` | clear → compact banner → challenges box → animation (Enter to continue) → flow box → Enter → prereqs → restore loop → argocd summary |

### Bash 3.2 compatibility rules (macOS default shell)
- **No `declare -A`** — use parallel indexed arrays instead
- **Guard empty array expansions** with `set -u` active:
  ```bash
  foo=()
  [[ ${#bar[@]} -gt 0 ]] && foo=("${bar[@]}")
  # or inline:
  foo=("${bar[@]+"${bar[@]}"}")
  ```
- `set -uo pipefail` is active throughout — unbound variables are fatal
- Use `printf` for column-aligned output (not `column`)

---

## Startup Sequence (`main`)

```
clear
→ Compact 3-line block-letter banner  (OPENSHIFT / DISASTER / RECOVERY)
→ Subtitle + separator line
→ CHALLENGES box (yellow) — backup/recovery challenges to consider
→ _play_dr_animation — loops 5 frames until Enter pressed
→ Flow box (oc-dr.sh steps overview)
→ Press Enter to continue
→ check_prereqs
→ run_prereq_restores
→ main restore loop (select backup → describe/filter → namespaces → YAML → confirm → restore → validate → loop?)
→ check_argocd_apps
```

### `_play_dr_animation` frames
Runs in background subshell, cycles continuously until user presses Enter:

| Frame | State | Colours | Delay |
|---|---|---|---|
| 1 | Normal Operation | green / dim | 0.8s |
| 2 | Incident Detected | yellow / dim | 0.6s |
| 3 | Cluster Down | red / dim | 1.2s |
| 4 | Failover | red → yellow | 1.5s |
| 5 | DR Recovered | dim → green | 2.0s |

Uses sentinel file `/tmp/dr_anim_XXXXXX` to signal stop. Clears animation area with `\033[1A\033[2K` per line on exit.

---

Steps run in strict dependency order — ORDER MATTERS.

| Step | Delegate fn | Backup pattern | Restore name | Resources | Namespace(s) |
|---|---|---|---|---|---|
| **1** | inline | `ose-infrastructure-backup-bankdata-resources-*` | `restore-bd-ns-crds-<ts>` | Namespace, NetworkPolicy, EgressFirewall | `"*"` |
| **2** | `_restore_db2_prereq` | `db2u-velero-backup-*` (user selects) | `restore-db2-<ns>-<ts>` | All except noise | auto-detected from Backup CR |
| **3** | `_restore_wcm_prereq` | `dxo-velero-backup-all-crds-*` + `pvc-only-*` | Phase A: `restore-<x>-sa-<ns>-<ts>`, Phase B: `restore-<x>-pvc-<ns>-<ts>` | A: ClusterRole+SA, B: all-except-noise+PVCs | auto-detected |
| **5** | inline | `ose-infrastructure-backup-ose-sealed-secrets-*` | `restore-sealed-secrets-<ts>` | All except noise | `ose-sealed-secrets` |
| **6+7** | `_restore_gitops_prereq` | `*gitops*` (all, loop) | `restore-gitops-<ns>-<ts>` | AppProject, Application | auto-detected per backup |
| **8** | `patch_argocd_destinations` | _(no backup)_ | — | Patches ArgoCD `spec.destination.server` | `ose-gitops`, `ose-gitops-bd` |

> Note: step numbers 4 in the original design were merged into steps 3 and 6+7.

### Adding a simple inline prereq
Add a new block inside `run_prereq_restores()` and call `_apply_prereq`:

```bash
  # Step N. My new prereq
  local backup ts yaml_file restore_name
  backup=$(_find_newest_backup "my-backup-prefix")
  if [[ -z "$backup" ]]; then
    warn "No backup matching 'my-backup-prefix*' found — skipping."
  else
    ok "Found prereq backup: ${backup}"
    ts=$(echo "$backup" | grep -oE '[0-9]{8}[0-9]*$')
    restore_name="restore-my-prefix-${ts}"
    yaml_file="${YAML_DIR}/prereq-N-my-prefix.yaml"
    cat > "$yaml_file" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup}
  includedResources:
    - MyResource
  includedNamespaces:
    - my-namespace
EOF
    prompt_ns_mapping_single "my-namespace"
    append_ns_mapping_to_yaml "$yaml_file" "my-namespace"
    _apply_prereq "$yaml_file" "$restore_name" "MyResources (my-namespace)"
  fi
```

---

## `_list_argocd_resources` — ArgoCD Resource Display

Called before and after each gitops prereq restore. Shows three sections per namespace:

1. **AppProjects** — names only
2. **Applications** — name, sync status, health status
3. **Secrets** (`argocd.argoproj.io/secret-type`) — decoded data with sensitive fields masked

```
  Secrets (argocd.argoproj.io/secret-type):
    ┌─ my-dr-cluster  [cluster]
    │  name                   dr-cluster
    │  server                 https://api.dr.paas.example.dk:6443
    │  insecure               false
    │  tlsClientCertData      ***masked***
    └────────────────────────────────────────
    ┌─ my-repo  [repository]
    │  url                    https://github.com/org/repo.git
    │  type                   git
    │  username               deploy-bot
    │  password               ***masked***
    └────────────────────────────────────────
```

**Masked fields**: `password`, `sshPrivateKey`, `bearerToken`, `token`, `tlsClientCertData`, `tlsClientCertKey`, `clientSecret`

**Display order**: `name → server → url → type → project → username → insecure → (sensitive) → remaining`

Uses `ARGOCD_SECRETS_JSON` env var to pass JSON to Python (avoids stdin/heredoc conflict).

---

## `_velero_describe_restore` — Post-Restore Summary

Called automatically by `wait_for_restore` on every terminal phase (Completed, WaitingForPluginOperations, PartiallyFailed, Failed). Execs into Velero pod and runs `velero restore describe <name> --details --insecure-skip-tls-verify`.

Output:
```
ℹ Restore describe: restore-db2-ose-db2-20260727-095856
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
<full velero describe output>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✔  Restored: 47  Skipped: 12
# or:
⚠  Restored: 0  Skipped: 47 — all resources were skipped (already exist?)
```

---

## `select_included_resources_interactive` — Resource Filter

Called after backup describe, before namespace selection. Parses `velero backup describe --details` output to extract resource kinds. User can select a subset to include — sets global `INCLUDE_RESOURCES` (comma-separated). Reset to `""` each main loop iteration. `render_restore_yaml` emits `includedResources:` block when set.

---

## `check_prereqs` — BSL Table

Prints a formatted table of BackupStorageLocations before the Available/warn message:

```
  NAME          PHASE       PROVIDER    LAST SYNC
  ────────────  ──────────  ──────────  ────────────────────
  default       Available   aws         2026-07-29T08:00:00Z
```

---

## Namespace Mapping

Every prereq and main restore namespace goes through `prompt_ns_mapping_single`:
- **Option 1** (default): restore to original namespace → `includedNamespaces: [ns]`
- **Option 2**: restore to DR namespace → `namespaceMapping: {ns: dr-ns}` (overwrites `includedNamespaces`)

Mappings are idempotent — each namespace is prompted only once per session.
`append_ns_mapping_to_yaml` rewrites the YAML file in-place after the prompt.

---

## Snapshot vs File-system Backup Detection

`_is_snapshot_backup BACKUP` checks:
- `spec.defaultVolumesToRestic == "false"` **AND** `spec.defaultVolumesToFsBackup == "false"` → CSI snapshot

`_restorePVs_yaml_line BACKUP` emits:
```yaml
  restorePVs: true          # file-system backup
  # — or —
  # snapshot backup (defaultVolumesToRestic/FsBackup=false)
  # restorePVs omitted — PVs will be restored from VolumeSnapshot
```

---

---

## Restore YAML Patterns

### Standard namespace restore
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

### With namespace mapping
```yaml
spec:
  backupName: nightly-backup-20260721-060000
  namespaceMapping:
    billing: billing-dr
  restorePVs: true
```

### Filtered — specific resources only (gitops prereq)
```yaml
spec:
  backupName: ose-infrastructure-backup-ose-gitops-20260721
  includedResources:
    - AppProject
    - Application
    - Secret
  includedNamespaces:
    - ose-gitops
```

### Filtered — exclude noise resources (sealed secrets / DB2)
```yaml
spec:
  backupName: ose-infrastructure-backup-ose-sealed-secrets-20260721
  excludedResources:
    - nodes
    - events
    - events.events.k8s.io
    - backups.velero.io
    - restores.velero.io
    - resticrepositories.velero.io
    - csinodes.storage.k8s.io
    - volumeattachments.storage.k8s.io
  includedNamespaces:
    - ose-sealed-secrets
```

---

## Restore Status Phases

| Phase | Script action |
|---|---|
| `New` / `""` (CR not found) | Keep polling — log "not yet found" |
| `""` (CR exists, no phase) | Keep polling — log "status.phase not yet set" |
| `InProgress` | Keep polling with elapsed timer |
| `Completed` | ✅ Return 0 |
| `WaitingForPluginOperations` | ✅ Return 0 (CSI async ops in flight — treated as success) |
| `WaitingForPluginOperationsPartiallyFailed` | ⚠ Return 2 — warn, prompt continue |
| `PartiallyFailed` | ⚠ Return 2 — warn, prompt continue |
| `Failed` | ❌ Return 1 — error, prompt continue or abort |
| oc command error (rc≠0) | ⚠ Warn with rc and namespace shown — keep polling |

---

## Backup Discovery Helpers

```bash
_find_newest_backup "prefix"          # newest where name matches ^prefix-\d
_find_newest_backup_containing "str"  # newest where name contains str
_list_backups_matching "str"          # all names containing str (one per line)
_list_newest_per_base_matching "str"  # newest per base name containing str
```

**Deduplication regex** (Python — strips timestamp suffix):
```python
import re
base = re.sub(r"-\d{8}-?\d{6}$", "", name)
if base == name:
    base = re.sub(r"-\d{8}$", "", name)
```

**Prefix matching** (avoids `ose-gitops` matching `ose-gitops-bd`):
```python
re.match(r'^PREFIX-\d', backup_name)
```

---

## Useful oc Commands for DR Debugging

```bash
# List all Backup CRs newest first
oc get backups.velero.io -n openshift-adp --sort-by=.metadata.creationTimestamp

# Describe a restore (shows warnings and errors)
oc describe restores.velero.io <restore-name> -n openshift-adp

# Velero pod logs
oc logs -n openshift-adp -l app.kubernetes.io/name=velero --tail=200

# All Restore CRs + phase
oc get restores.velero.io -n openshift-adp \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,BACKUP:.spec.backupName'

# Watch restores live
watch -n5 'oc get restores.velero.io -n openshift-adp'

# PVCs not Bound
oc get pvc -n <ns> --no-headers | awk '$2!="Bound"'

# Pods not Running/Ready
oc get pods -n <ns> --no-headers | awk '{split($2,a,"/"); if(a[1]!=a[2]||$3!="Running") print}'

# ArgoCD app health
oc get applications.argoproj.io -n ose-gitops \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# BackupStorageLocation status
oc get backupstoragelocations.velero.io -n openshift-adp
```

---

## Output File Layout

```
./dr-logs/
├── dr-run-<ts>.log
├── dr-summary-<ts>.txt
└── restore-manifests-<ts>/
    ├── prereq-1-bankdata-resources.yaml
    ├── prereq-db2-<ns>.yaml
    ├── prereq-wcm-<ns>-a-sa.yaml
    ├── prereq-wcm-<ns>-b-pvc.yaml
    ├── prereq-5-ose-sealed-secrets.yaml
    ├── prereq-gitops-<n>-<ns>.yaml
    └── restore-<ns>.yaml             # one per main restore namespace
```

---

## Common Usage

```bash
./oc-dr.sh                                         # fully interactive (recommended)
./oc-dr.sh --dry-run                               # render all YAMLs, never apply
./oc-dr.sh -l                                      # list available backups and exit
./oc-dr.sh -b backup-20260721 -n "billing,auth"    # non-interactive single restore
./oc-dr.sh -b backup-a,backup-b                    # multiple backups
VELERO_NS=velero ./oc-dr.sh                        # override Velero namespace
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `unbound variable` on array | Bash 3.2 + `set -u` + empty array | `[[ ${#arr[@]} -gt 0 ]] && ...` |
| `declare -A` fails | Bash 3.2 (macOS) no assoc arrays | Use parallel indexed arrays |
| Restore stuck in `New` | Velero pod not running / BSL unavailable | `oc get pods -n openshift-adp` |
| `PartiallyFailed` | Resources conflict (already exist) | `oc describe restores.velero.io <name> -n openshift-adp` |
| PVCs not Bound | CSI snapshot not synced or wrong StorageClass | Check VolumeSnapshot / StorageClass |
| Routes not Admitted | Router pod not running | `oc get pods -n openshift-ingress` |
| Prereq backup not found | Name prefix mismatch | `oc get backups.velero.io -n openshift-adp` |
| ArgoCD apps not syncing | Sealed secrets missing or gitops prereq not run | Re-run prereqs in order |
| Wrong `spec.destination.server` | Source and DR cluster have different API URLs | Run `patch_argocd_destinations` (step 8) |
| `velero describe restore` fails | Velero pod not found or binary not at `/velero` | Check `oc get pods -n openshift-adp -l app.kubernetes.io/name=velero` |
| ArgoCD secret data empty | Secret not restored (gitops prereq skipped) | Re-run `_restore_gitops_prereq`; check `Secret` in `includedResources` |
| `JSONDecodeError` in secrets display | Python received empty stdin (heredoc conflict) | Pass JSON via env var `ARGOCD_SECRETS_JSON` — already fixed in current version |
| Animation doesn't stop on Enter | `\033[J` cleared "Press Enter" prompt | Fixed: use `\033[1A\033[2K` per-line rewind |
| Python f-string syntax error | Python < 3.12 rejects `f"{\"NAME\":<40}"` | Use `%`-formatting: `"%-40s" % value` — applies everywhere in script |

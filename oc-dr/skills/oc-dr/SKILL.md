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
| Function | Purpose |
|---|---|
| `check_prereqs` | oc login, python3, OADP CRDs, Velero pod, BSL status |
| `list_backups` | `-l` flag: print newest per base name and exit |
| `select_backup_interactive` | Numbered menu, supports `1`, `1,3`, `all` |
| `validate_backup` | Checks backup phase (Completed / PartiallyFailed / other) |
| `get_backup_included_namespaces` | Reads `spec.includedNamespaces` from Backup CR |
| `select_namespaces_interactive` | Namespace picker per backup |
| `get_ns_mapping NS` | Returns DR target ns for NS, or `""` if original |
| `_ns_mapping_recorded NS` | Returns 0 if NS already prompted (idempotent) |
| `prompt_ns_mapping_single NS` | Interactive: original ns or DR mapped ns (once per ns) |
| `append_ns_mapping_to_yaml FILE NS` | Rewrites YAML: swaps `includedNamespaces` → `namespaceMapping` |
| `prompt_namespace_mapping NS_LIST` | Calls `prompt_ns_mapping_single` for each ns in CSV list |
| `pre_restore_check NS` | Warns if ns already exists with resources |
| `_is_snapshot_backup BACKUP` | Returns 0 if CSI snapshot backup (no Restic/Kopia) |
| `_restorePVs_yaml_line BACKUP` | Emits `restorePVs: true` or snapshot comment |
| `render_restore_yaml NS NAME FILE TARGET_NS` | Writes Restore CR YAML (with mapping if target_ns set) |
| `create_restore NS` | render + dry-run print or `oc apply` |
| `wait_for_restore NAME` | Polls `status.phase` with elapsed timer, handles all phases |
| `validate_namespace NS` | Checks pods/PVCs/routes post-restore |
| `_show_yaml_box FILE` | Prints YAML inside a `┌─┐` border box |
| `_apply_prereq FILE NAME DESC` | Show box → prompt → apply → wait → handle rc |
| `_find_newest_backup PREFIX` | Newest backup matching `^PREFIX-\d` |
| `_find_newest_backup_containing STR` | Newest backup whose name contains STR |
| `_list_backups_matching STR` | All backup names containing STR |
| `_list_newest_per_base_matching STR` | Newest per base name among backups containing STR |
| `_restore_db2_prereq` | Lists `db2u-velero-backup-*`, user selects, pre-renders + applies |
| `_restore_wcm_prereq` | Lists `dxo-velero-backup-all-crds-*` + `pvc-only-*`, Phase A→B |
| `_list_argocd_resources NS LABEL` | Lists AppProjects + Applications in ns (before/after restore) |
| `_restore_gitops_prereq` | Loop over all `*gitops*` backups in dependency order |
| `run_prereq_restores` | Orchestrates all prereq steps 1–8 in order |
| `patch_argocd_destinations` | Patches ArgoCD `spec.destination.server` to DR cluster URL |
| `check_argocd_apps` | Final summary: lists Sync/Health of all ArgoCD apps |
| `main` | Banner → prereqs → loop(select→preview→confirm→restore→loop?) → argocd summary |

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

## Prerequisite Restore Order (`run_prereq_restores`)

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

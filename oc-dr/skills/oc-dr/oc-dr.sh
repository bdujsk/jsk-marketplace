#!/usr/bin/env bash
#
# oc-dr.sh — OpenShift Disaster Recovery via Velero / OADP
#
# This script guides you through a full DR restore on an OpenShift cluster
# using Velero (OADP) Backup CRs. It requires only the `oc` CLI — no separate
# velero binary needed.
#
# Flow:
#   1. Checks prerequisites (oc logged in, OADP CRDs present, Velero running)
#   2. Runs prerequisite restores in order (namespaces/policies, sealed secrets,
#      ArgoCD app projects) — each shown as YAML with an apply prompt
#   3. Presents a deduplicated list of available backups (newest per base name)
#      and lets you select one or more (e.g. "1,3" or "all")
#   4. For each selected backup, lets you pick which namespaces to restore
#   5. Renders all Restore CRs as YAML and shows them for review
#   6. Asks once: run recovery now, or just save the YAML without applying
#   7. Applies the restores, polls for completion with live status updates,
#      then validates pods, PVCs and routes in each restored namespace
#   8. Asks if you want to restore another backup (interactive loop)
#   9. Writes a timestamped log and summary report to ./dr-logs/
#
# Usage:
#   ./oc-dr.sh                              # fully interactive (recommended)
#   ./oc-dr.sh -b <backup> -n "ns1,ns2"    # non-interactive single restore
#   ./oc-dr.sh -b backup1,backup2          # restore multiple backups
#   ./oc-dr.sh -l                          # list available backups and exit
#   ./oc-dr.sh --dry-run                   # render YAML only, never apply
#   ./oc-dr.sh --help                      # full option list
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults (override via flags or environment)
# ---------------------------------------------------------------------------
VELERO_NS="${VELERO_NS:-openshift-adp}"          # namespace Velero/OADP runs in
BACKUP_NAMES=()
BACKUP_NAME=""                                   # set per-backup in main loop
NAMESPACES="${NAMESPACES:-}"                     # comma-separated list (-n flag, applies to all backups)
RESTORE_ALL_NAMESPACES=false
RESTORE_NAME_PREFIX="${RESTORE_NAME_PREFIX:-dr-restore}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"             # seconds between status checks
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-1800}"        # seconds (30 min) per restore
DRY_RUN=false
LOG_DIR="${LOG_DIR:-./dr-logs}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/dr-run-${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/dr-summary-${TIMESTAMP}.txt"
RESTORE_PVS=true
EXCLUDE_RESOURCES="${EXCLUDE_RESOURCES:-}"         # comma-separated, e.g. "events,events.events.k8s.io"
WAIT_FOR_APP_READY_TIMEOUT="${WAIT_FOR_APP_READY_TIMEOUT:-300}"
YAML_DIR="${LOG_DIR}/restore-manifests-${TIMESTAMP}"
NON_INTERACTIVE=false
LIST_ONLY=false
NS_MAPPING_ORIG=()    # parallel arrays: original ns name
NS_MAPPING_TARGET=()  # parallel arrays: DR target ns name (empty = restore to original)
INCLUDE_RESOURCES=""  # comma-separated resource types to include (empty = all)

# Velero CRD group used throughout (as registered by the OADP operator on OpenShift)
BACKUP_CRD="backups.velero.io"
RESTORE_CRD="restores.velero.io"

# ---------------------------------------------------------------------------
# Colors / logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

mkdir -p "$LOG_DIR"

log()   { local msg; msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"; echo -e "$msg" | tee -a "$LOG_FILE" >&2; }
info()  { log "${BLUE}INFO${NC}  $*"; }
warn()  { log "${YELLOW}WARN${NC}  $*"; }
error() { log "${RED}ERROR${NC} $*"; }
ok()    { log "${GREEN}OK${NC}    $*"; }

die() { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Automated OpenShift Disaster Recovery via Velero (oc + YAML only, no velero CLI)

Usage:
  $0 -b BACKUP_NAME -n "ns1,ns2,ns3" [options]
  $0 -l
  $0                              # fully interactive
  $0 -b BACKUP_NAME --all-namespaces

Required (unless -l used):
  -b, --backup NAME           Name of the Backup CR to restore from. If omitted,
                               an interactive menu of Backup CRs is shown
                               (unless --non-interactive is set).
  -n, --namespaces LIST       Comma-separated namespaces to restore (mutually
                               exclusive with --all-namespaces). If omitted,
                               an interactive menu of namespaces found in the
                               chosen backup is shown.

Options:
      --all-namespaces        Restore all namespaces contained in the backup
      --velero-ns NAME        Namespace where Velero/OADP is installed (default: ${VELERO_NS})
      --restore-prefix NAME   Prefix for generated Restore CR names (default: ${RESTORE_NAME_PREFIX})
      --exclude-resources L   Comma-separated resource types to exclude from restore
      --no-restore-pvs        Do not restore PersistentVolumes
      --timeout SECONDS       Max seconds to wait per restore (default: ${RESTORE_TIMEOUT})
      --poll-interval SECONDS Seconds between status polls (default: ${POLL_INTERVAL})
      --dry-run               Render Restore YAML but do not apply it
      --non-interactive       Never prompt; fail instead if -b/-n are missing
                               (use for CI/cron)
  -l, --list                  List available Backup CRs and exit
  -h, --help                  Show this help

Examples:
  $0 -l
  $0 -b nightly-backup-20260709 -n "billing,inventory,auth"
  $0 -b nightly-backup-20260709 --all-namespaces --dry-run
  $0                                   # picks backup + namespaces interactively
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--backup) IFS=',' read -ra _btmp <<< "$2"; [[ ${#_btmp[@]} -gt 0 ]] && BACKUP_NAMES+=("${_btmp[@]}"); shift 2 ;;
    -n|--namespaces) NAMESPACES="$2"; shift 2 ;;
    --all-namespaces) RESTORE_ALL_NAMESPACES=true; shift ;;
    --velero-ns) VELERO_NS="$2"; shift 2 ;;
    --restore-prefix) RESTORE_NAME_PREFIX="$2"; shift 2 ;;
    --exclude-resources) EXCLUDE_RESOURCES="$2"; shift 2 ;;
    --no-restore-pvs) RESTORE_PVS=false; shift ;;
    --timeout) RESTORE_TIMEOUT="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -l|--list) LIST_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prereqs() {
  info "Checking prerequisites..."
  command -v oc >/dev/null 2>&1 || die "'oc' CLI not found in PATH."
  command -v python3 >/dev/null 2>&1 || die "'python3' not found in PATH (used for JSON parsing)."

  oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster. Run 'oc login' first."
  local user cluster
  user="$(oc whoami 2>/dev/null)"
  cluster="$(oc whoami --show-server 2>/dev/null)"
  info "Logged in as '${user}' against cluster '${cluster}'"

  oc get ns "$VELERO_NS" >/dev/null 2>&1 || die "Velero namespace '${VELERO_NS}' not found. Set --velero-ns correctly."

  oc get crd "$BACKUP_CRD" >/dev/null 2>&1 || die "CRD '${BACKUP_CRD}' not found on cluster. Is OADP/Velero installed?"
  oc get crd "$RESTORE_CRD" >/dev/null 2>&1 || die "CRD '${RESTORE_CRD}' not found on cluster. Is OADP/Velero installed?"

  if ! oc get pods -n "$VELERO_NS" -l app.kubernetes.io/name=velero --no-headers 2>/dev/null | grep -q Running; then
    warn "Could not confirm a Running Velero pod (label app.kubernetes.io/name=velero) in ${VELERO_NS}; continuing anyway."
  fi

  # Check BackupStorageLocation availability — if not Available, source backups may not be visible
  local bsl_json
  bsl_json=$(oc get backupstoragelocations.velero.io -n "$VELERO_NS" -o json 2>/dev/null)
  local bsl_not_available
  bsl_not_available=$(echo "$bsl_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=[i["metadata"]["name"] for i in d.get("items",[])
     if i.get("status",{}).get("phase","") != "Available"]
print(",".join(bad))
' 2>/dev/null)

  # Always print BSL table
  echo "" | tee -a "$LOG_FILE"
  info "BackupStorageLocation(s) in '${VELERO_NS}':"
  echo "$bsl_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
items=d.get("items",[])
if not items:
    print("  (none found)")
else:
    h1="NAME"; h2="PHASE"; h3="PROVIDER"; h4="LAST SYNC"
    print("  %-40s  %-12s  %-20s  %s" % (h1, h2, h3, h4))
    print("  %-40s  %-12s  %-20s  %s" % ("-"*40, "-"*12, "-"*20, "-"*25))
    for i in items:
        name=i["metadata"]["name"]
        phase=i.get("status",{}).get("phase","Unknown")
        provider=i.get("spec",{}).get("provider","")
        sync=i.get("status",{}).get("lastSyncedTime","")
        print("  %-40s  %-12s  %-20s  %s" % (name, phase, provider, sync))
' 2>/dev/null | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"

  if [[ -n "$bsl_not_available" ]]; then
    warn "BackupStorageLocation(s) NOT Available: ${bsl_not_available}. Backups from the source cluster may not be visible. Check that the bucket/prefix points to the correct source cluster."
  else
    ok "BackupStorageLocation(s) Available."
  fi

  mkdir -p "$YAML_DIR"
  ok "Prerequisites satisfied."
}

list_backups() {
  info "Backup CRs (${BACKUP_CRD}) in namespace '${VELERO_NS}' (newest per base name):"
  oc get "$BACKUP_CRD" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c '
import json, sys, re
d = json.load(sys.stdin)
groups = {}
for item in d.get("items", []):
    name = item["metadata"]["name"]
    status = item.get("status", {})
    phase = status.get("phase", "Unknown")
    created = item["metadata"].get("creationTimestamp", "")
    expires = status.get("expiration", "")
    base = re.sub(r"-\d{8}-?\d{6}$", "", name)
    if base == name:
        base = re.sub(r"-\d{8}$", "", name)
    if base not in groups or created > groups[base][2]:
        groups[base] = (name, phase, created, expires)
print(f"  {\"NAME\":<40} {\"PHASE\":<16} {\"CREATED\":<25} {\"EXPIRES\"}")
print(f"  {\"-\"*40} {\"-\"*16} {\"-\"*25} {\"-\"*25}")
for base in sorted(groups):
    name, phase, created, expires = groups[base]
    print(f"  {name:<40} {phase:<16} {created:<25} {expires}")
' 2>/dev/null | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Interactive picker: choose one or more backups from a numbered menu
# ---------------------------------------------------------------------------
select_backup_interactive() {
  $NON_INTERACTIVE && die "No backup specified (-b) and --non-interactive is set."
  [[ -t 0 ]] || die "No backup specified (-b) and no TTY available for interactive selection."

  info "No backup specified. Fetching Backup CRs from namespace '${VELERO_NS}'..."

  local raw
  raw=$(oc get "$BACKUP_CRD" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c '
import json, sys, re
d = json.load(sys.stdin)
groups = {}
for item in d.get("items", []):
    name = item["metadata"]["name"]
    status = item.get("status", {})
    phase = status.get("phase", "Unknown")
    created = item["metadata"].get("creationTimestamp", "")
    expires = status.get("expiration", "")
    base = re.sub(r"-\d{8}-?\d{6}$", "", name)
    if base == name:
        base = re.sub(r"-\d{8}$", "", name)
    if base not in groups or created > groups[base][2]:
        groups[base] = (name, phase, created, expires)
for base in sorted(groups):
    name, phase, created, expires = groups[base]
    print(f"{name}|{phase}|{created}|{expires}")
' 2>/dev/null)

  [[ -n "$raw" ]] || die "No Backup CRs found in namespace '${VELERO_NS}'."

  local names=() phases=() createds=() expires_arr=()
  while IFS='|' read -r name phase created expires; do
    [[ -z "$name" ]] && continue
    names+=("$name"); phases+=("$phase"); createds+=("$created"); expires_arr+=("$expires")
  done <<< "$raw"

  echo "" | tee -a "$LOG_FILE"
  printf "  %-3s  %-75s  %-13s  %-20s  %-20s\n" "#" "BACKUP NAME" "STATUS" "CREATED" "EXPIRES" | tee -a "$LOG_FILE"
  printf "  %-3s  %-75s  %-13s  %-20s  %-20s\n" "---" "---------------------------------------------------------------------------" "-------------" "--------------------" "--------------------" | tee -a "$LOG_FILE"
  local i
  for i in "${!names[@]}"; do
    local created_fmt expires_fmt phase_fmt
    created_fmt=$(echo "${createds[$i]}" | sed 's/T/ /; s/Z//')
    expires_fmt=$(echo "${expires_arr[$i]}" | sed 's/T/ /; s/Z//')
    case "${phases[$i]}" in
      Completed)       phase_fmt="✔ Completed" ;;
      PartiallyFailed) phase_fmt="⚠ Partial" ;;
      Failed)          phase_fmt="✖ Failed" ;;
      *)               phase_fmt="? ${phases[$i]}" ;;
    esac
    printf "  %-3s  %-75s  %-13s  %-20s  %-20s\n" "$((i+1))" "${names[$i]}" "$phase_fmt" "$created_fmt" "$expires_fmt" | tee -a "$LOG_FILE"
  done
  echo "" | tee -a "$LOG_FILE"

  local idx_list=() picked_names=() picked_phases=()
  local choice
  while true; do
    read -r -p "Select backup(s) by number (e.g. '1' or '1,3' or 'all'), or 'q' to quit: " choice
    [[ "$choice" == "q" ]] && die "Cancelled by user."

    idx_list=(); picked_names=(); picked_phases=()
    local valid=true
    if [[ "$choice" == "all" ]]; then
      for i in "${!names[@]}"; do idx_list+=("$((i+1))"); done
    else
      IFS=',' read -ra idx_list <<< "$choice"
    fi

    for idx in "${idx_list[@]}"; do
      idx="$(echo "$idx" | tr -d '[:space:]')"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#names[@]} )); then
        picked_names+=("${names[$((idx-1))]}")
        picked_phases+=("${phases[$((idx-1))]}")
      else
        warn "Invalid selection: '${idx}'"
        valid=false
      fi
    done

    if $valid && [[ ${#picked_names[@]} -gt 0 ]]; then
      break
    fi
    warn "Please enter valid number(s)."
  done

  BACKUP_NAMES=("${picked_names[@]+"${picked_names[@]}"}")

  local non_complete=false
  for i in "${!BACKUP_NAMES[@]}"; do
    if [[ "${picked_phases[$i]}" != "Completed" ]]; then
      warn "Backup '${BACKUP_NAMES[$i]}' has phase '${picked_phases[$i]}', not 'Completed'."
      non_complete=true
    fi
  done
  if $non_complete; then
    read -r -p "Proceed with non-Completed backup(s)? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Cancelled by user."
  fi

  ok "Selected backup(s): ${BACKUP_NAMES[*]}"
}

# ---------------------------------------------------------------------------
# Validate the requested backup exists and is Completed
# ---------------------------------------------------------------------------
validate_backup() {
  [[ -n "$BACKUP_NAME" ]] || die "No backup name specified. Use -b/--backup or -l to list backups."

  info "Validating backup '${BACKUP_NAME}'..."
  local phase
  phase=$(oc get "$BACKUP_CRD" "$BACKUP_NAME" -n "$VELERO_NS" -o json 2>/dev/null | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",{}).get("phase","Unknown"))' 2>/dev/null)

  [[ -n "$phase" ]] || die "Backup '${BACKUP_NAME}' not found in namespace '${VELERO_NS}'."

  case "$phase" in
    Completed) ok "Backup '${BACKUP_NAME}' phase: Completed" ;;
    PartiallyFailed) warn "Backup '${BACKUP_NAME}' phase: PartiallyFailed - restore may be incomplete." ;;
    *) die "Backup '${BACKUP_NAME}' is in phase '${phase}', not safe to restore from." ;;
  esac
}

# ---------------------------------------------------------------------------
# Get the namespace list a given backup actually contains (from its spec)
# ---------------------------------------------------------------------------
get_backup_included_namespaces() {
  oc get "$BACKUP_CRD" "$BACKUP_NAME" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
ns = d.get("spec", {}).get("includedNamespaces", [])
ns = [n for n in ns if n != "*"]
print(",".join(ns))
' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Interactive picker: choose namespaces contained in the selected backup
# ---------------------------------------------------------------------------
select_namespaces_interactive() {
  $NON_INTERACTIVE && die "No namespaces specified (-n) and --non-interactive is set."
  [[ -t 0 ]] || die "No namespaces specified (-n) and no TTY available for interactive selection."

  info "Discovering namespaces included in backup '${BACKUP_NAME}'..."
  local avail=()
  IFS=',' read -ra avail <<< "$(get_backup_included_namespaces)"

  if [[ ${#avail[@]} -eq 0 || -z "${avail[0]}" ]]; then
    warn "Backup targets all namespaces ('*') or namespace list could not be parsed from spec.includedNamespaces."
    read -r -p "Enter comma-separated namespace names to restore: " NAMESPACES
    [[ -n "$NAMESPACES" ]] || die "No namespaces entered."
    return 0
  fi

  echo "" | tee -a "$LOG_FILE"
  info "Namespaces included in backup '${BACKUP_NAME}':"
  local i
  for i in "${!avail[@]}"; do
    printf "  %-4s %s\n" "$((i+1))" "${avail[$i]}" | tee -a "$LOG_FILE"
  done
  echo "" | tee -a "$LOG_FILE"

  local choice
  read -r -p "Select namespaces by number (e.g. '1,3,4' or 'all'): " choice
  [[ -n "$choice" ]] || die "No selection made."

  if [[ "$choice" == "all" ]]; then
    NAMESPACES=$(IFS=,; echo "${avail[*]}")
  else
    local picked=() idx
    IFS=',' read -ra idx_list <<< "$choice"
    for idx in "${idx_list[@]}"; do
      idx="$(echo "$idx" | tr -d '[:space:]')"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#avail[@]} )); then
        picked+=("${avail[$((idx-1))]}")
      else
        warn "Ignoring invalid selection: '${idx}'"
      fi
    done
    [[ ${#picked[@]} -gt 0 ]] || die "No valid namespaces selected."
    NAMESPACES=$(IFS=,; echo "${picked[*]}")
  fi

  ok "Selected namespaces: ${NAMESPACES}"
}

# ---------------------------------------------------------------------------
# Determine the namespace list to act on
# ---------------------------------------------------------------------------
resolve_namespaces() {
  if $RESTORE_ALL_NAMESPACES; then
    info "Discovering namespaces included in backup '${BACKUP_NAME}'..."
    IFS=',' read -ra NS_ARRAY <<< "$(get_backup_included_namespaces)"
    if [[ ${#NS_ARRAY[@]} -eq 0 || -z "${NS_ARRAY[0]}" ]]; then
      die "Backup '${BACKUP_NAME}' targets '*' (all namespaces) or list could not be parsed; re-run with -n explicit list instead of --all-namespaces."
    fi
  else
    [[ -n "$NAMESPACES" ]] || die "No namespaces specified. Use -n/--namespaces or --all-namespaces."
    IFS=',' read -ra NS_ARRAY <<< "$NAMESPACES"
  fi
  info "Target namespaces: ${NS_ARRAY[*]}"
}

# ---------------------------------------------------------------------------
# Lookup: given an original namespace, return the DR target namespace (or "")
# ---------------------------------------------------------------------------
get_ns_mapping() {
  local orig="$1" i
  for i in "${!NS_MAPPING_ORIG[@]}"; do
    [[ "${NS_MAPPING_ORIG[$i]}" == "$orig" ]] && { echo "${NS_MAPPING_TARGET[$i]}"; return; }
  done
  echo ""
}

# Returns 0 if the namespace has already been recorded, 1 otherwise
_ns_mapping_recorded() {
  local orig="$1" i
  for i in "${!NS_MAPPING_ORIG[@]}"; do
    [[ "${NS_MAPPING_ORIG[$i]}" == "$orig" ]] && return 0
  done
  return 1
}

# Prompt for a single namespace mapping (idempotent — skips if already asked).
# Records result in NS_MAPPING_ORIG / NS_MAPPING_TARGET.
prompt_ns_mapping_single() {
  local orig_ns="$1"
  _ns_mapping_recorded "$orig_ns" && return 0   # already asked
  if $NON_INTERACTIVE; then
    NS_MAPPING_ORIG+=("$orig_ns"); NS_MAPPING_TARGET+=(""); return 0
  fi
  echo ""
  info "Namespace '${orig_ns}': restore destination?"
  echo "  1) Original namespace  (includedNamespaces: ${orig_ns})"
  echo "  2) New DR namespace    (namespaceMapping:   ${orig_ns} -> <target>)"
  local choice dr_ns
  read -r -p "  Choose [1/2, default 1]: " choice
  if [[ "$choice" == "2" ]]; then
    read -r -p "  Enter DR target namespace for '${orig_ns}': " dr_ns
    if [[ -z "$dr_ns" ]]; then
      warn "No DR namespace entered — using original namespace '${orig_ns}'."
      dr_ns=""
    else
      ok "  '${orig_ns}' will be mapped -> '${dr_ns}'"
    fi
  else
    dr_ns=""
  fi
  NS_MAPPING_ORIG+=("$orig_ns")
  NS_MAPPING_TARGET+=("$dr_ns")
}

# Append a namespaceMapping stanza to an already-written YAML file (no-op if no mapping).
append_ns_mapping_to_yaml() {
  local yaml_file="$1" orig_ns="$2"
  local target
  target="$(get_ns_mapping "$orig_ns")"
  if [[ -n "$target" ]]; then
    # Strip the includedNamespaces block (key line + its "    - ..." entries)
    local tmp
    tmp=$(mktemp)
    awk '/^  includedNamespaces:/{skip=1;next} skip && /^    - /{next} {skip=0;print}' "$yaml_file" > "$tmp"
    mv "$tmp" "$yaml_file"
    printf '  namespaceMapping:\n    %s: %s\n' "$orig_ns" "$target" >> "$yaml_file"
  fi
}

# ---------------------------------------------------------------------------
# Prompt namespace mapping for a comma-separated list (calls prompt_ns_mapping_single).
# ---------------------------------------------------------------------------
prompt_namespace_mapping() {
  local ns_list="$1" ns
  IFS=',' read -ra _nm_arr <<< "$ns_list"
  for ns in "${_nm_arr[@]}"; do
    prompt_ns_mapping_single "$ns"
  done
}

# ---------------------------------------------------------------------------
# Pre-restore safety check: warn if namespace already exists with resources
# ---------------------------------------------------------------------------
pre_restore_check() {
  local ns="$1"
  if oc get ns "$ns" >/dev/null 2>&1; then
    local count
    count=$(oc get all -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
      warn "Namespace '${ns}' already exists and contains ${count} resources. Velero restore skips resources that already exist unless the Restore's existingResourcePolicy is set to 'update'. Review manually if this is unexpected."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Detect if a backup used CSI/VolumeSnapshots (not restic/fs-backup).
# Returns 0 (true) when both defaultVolumesToRestic and defaultVolumesToFsBackup
# are explicitly "false" in the backup spec.
# ---------------------------------------------------------------------------
_is_snapshot_backup() {
  local backup_name="${1:-$BACKUP_NAME}"
  local restic fsbackup
  restic=$(oc get "$BACKUP_CRD" "$backup_name" -n "$VELERO_NS" \
    -o jsonpath='{.spec.defaultVolumesToRestic}' 2>/dev/null)
  fsbackup=$(oc get "$BACKUP_CRD" "$backup_name" -n "$VELERO_NS" \
    -o jsonpath='{.spec.defaultVolumesToFsBackup}' 2>/dev/null)
  [[ "$restic" == "false" && "$fsbackup" == "false" ]]
}

# Emit either a YAML restorePVs line or a snapshot comment, with 2-space indent.
_restorePVs_yaml_line() {
  local backup_name="${1:-$BACKUP_NAME}"
  if _is_snapshot_backup "$backup_name"; then
    printf '  # snapshot backup (defaultVolumesToRestic/FsBackup=false)\n'
    printf '  # restorePVs omitted — PVs will be restored from VolumeSnapshot\n'
  else
    echo "  restorePVs: true"
  fi
}

# ---------------------------------------------------------------------------
# Startup animation — tiny ASCII disaster-recovery scenario (≈4 s)
# Plays in-place using ANSI cursor-up to overwrite frames.
# ---------------------------------------------------------------------------
_play_dr_animation() {
  local RD='\033[1;31m' GR='\033[1;32m' YL='\033[1;33m'
  local DM='\033[2m'    BD='\033[1m'    R='\033[0m'
  local F=7   # lines printed per frame (including leading blank)

  # Print a blank placeholder so rewind works from the first frame
  printf "\n\n\n\n\n\n\n"

  _dr_rewind() {
    local i
    for (( i=0; i<F; i++ )); do printf "\033[1A\033[2K"; done
    printf "\r"
  }

  _dr_frame() {
    local hdr="$1" hdr_color="$2"
    local left_color="$3" left_status="$4"
    local arrow="$5"
    local right_color="$6" right_a="$7" right_b="$8" right_status="$9"
    printf "  ${BD}%-22s${R}  ${hdr_color}%-26s${R}  ${BD}%s${R}\n" \
      "PRIMARY CLUSTER" "$hdr" "DR CLUSTER"
    printf "  ${left_color}╔════════════════╗${R}  ${arrow}  ${right_color}╔════════════════╗${R}\n"
    printf "  ${left_color}║ ${left_a} api  ${left_a} db  ║${R}                            ${right_color}║ ${right_a} api  ${right_a} db  ║${R}\n"
    printf "  ${left_color}║ ${left_a} app  ${left_a} store║${R}                            ${right_color}║ ${right_b} app  ${right_b} store║${R}\n"
    printf "  ${left_color}╚════════════════╝${R}  ${left_color}${left_status}${R}\n"
    printf "\n"
  }

  # Run animation loop in background subshell; stop when sentinel file appears
  local _sentinel
  _sentinel=$(mktemp /tmp/dr_anim_XXXXXX)
  rm -f "$_sentinel"   # we watch for its creation

  (
    while [[ ! -e "$_sentinel" ]]; do
      # Frame 1 — Normal
      _dr_rewind
      printf "\n"
      printf "  ${BD}%-22s${R}  %-26s  ${BD}%s${R}\n" \
        "PRIMARY CLUSTER" "Normal Operation" "DR CLUSTER"
      printf "  ${GR}╔════════════════╗${R}   ══════════════════>    ${DM}╔════════════════╗${R}\n"
      printf "  ${GR}║ ● api   ● db   ║${R}                          ${DM}║ ○ api   ○ db   ║${R}\n"
      printf "  ${GR}║ ● app   ● store║${R}                          ${DM}║ ○ app   ○ store║${R}\n"
      printf "  ${GR}╚════════════════╝${R}   ${GR}[ HEALTHY  ✔ ]${R}         ${DM}╚════════════════╝${R}\n"
      printf "\n"
      [[ -e "$_sentinel" ]] && break; sleep 4

      # Frame 2 — Incident
      _dr_rewind
      printf "\n"
      printf "  ${BD}%-22s${R}  ${YL}%-26s${R}  ${BD}%s${R}\n" \
        "PRIMARY CLUSTER" "!! INCIDENT DETECTED !!" "DR CLUSTER"
      printf "  ${YL}╔════════════════╗${R}  ═══ ${YL}⚡ FAULT ⚡${R} ═════>  ${DM}╔════════════════╗${R}\n"
      printf "  ${YL}║ ◐ api   ◐ db   ║${R}                          ${DM}║ ○ api   ○ db   ║${R}\n"
      printf "  ${YL}║ ◐ app   ◐ store║${R}                          ${DM}║ ○ app   ○ store║${R}\n"
      printf "  ${YL}╚════════════════╝${R}   ${YL}[ WARNING  ! ]${R}         ${DM}╚════════════════╝${R}\n"
      printf "\n"
      [[ -e "$_sentinel" ]] && break; sleep 4

      # Frame 3 — Outage
      _dr_rewind
      printf "\n"
      printf "  ${BD}%-22s${R}  ${RD}%-26s${R}  ${BD}%s${R}\n" \
        "PRIMARY CLUSTER" "!!! CLUSTER  DOWN  !!!" "DR CLUSTER"
      printf "  ${RD}╔════════════════╗${R}  × × × × × × × × × × ×   ${DM}╔════════════════╗${R}\n"
      printf "  ${RD}║ ✗ api   ✗ db   ║${R}                          ${DM}║ ○ api   ○ db   ║${R}\n"
      printf "  ${RD}║ ✗ app   ✗ store║${R}                          ${DM}║ ○ app   ○ store║${R}\n"
      printf "  ${RD}╚════════════════╝${R}   ${RD}[ OUTAGE   ✗ ]${R}         ${DM}╚════════════════╝${R}\n"
      printf "\n"
      [[ -e "$_sentinel" ]] && break; sleep 4

      # Frame 4 — Failover
      _dr_rewind
      printf "\n"
      printf "  ${BD}%-22s${R}  ${YL}%-26s${R}  ${BD}%s${R}\n" \
        "PRIMARY CLUSTER" "<<< VELERO RECOVERY >>>" "DR CLUSTER"
      printf "  ${RD}╔════════════════╗${R}   ══════════════════>   ${YL}╔════════════════╗${R}\n"
      printf "  ${RD}║ ✗ ✗ ✗ ✗ ✗ ✗    ║${R}                         ${YL}║ ◎ api   ◎ db   ║${R}\n"
      printf "  ${RD}║ ✗ ✗ ✗ ✗ ✗ ✗    ║${R}                         ${YL}║ ◎ app   ◎ store║${R}\n"
      printf "  ${RD}╚════════════════╝${R}   ${RD}[ DOWN     ✗ ]${R}        ${YL}╚════════════════╝${R}\n"
      printf "\n"
      [[ -e "$_sentinel" ]] && break; sleep 4

      # Frame 5 — Recovered
      _dr_rewind
      printf "\n"
      printf "  ${BD}%-22s${R}  ${GR}%-26s${R}  ${BD}%s${R}\n" \
        "PRIMARY CLUSTER" "DR CLUSTER RECOVERED ✔" "DR CLUSTER (ONLINE)"
      printf "  ${DM}╔════════════════╗${R}   ══════════════════>   ${GR}╔════════════════╗${R}\n"
      printf "  ${DM}║ ✗ ✗ ✗ ✗ ✗ ✗    ║${R}                         ${GR}║ ● api   ● db   ║${R}\n"
      printf "  ${DM}║ ✗ ✗ ✗ ✗ ✗ ✗    ║${R}                         ${GR}║ ● app   ● store║${R}\n"
      printf "  ${DM}╚════════════════╝${R}   ${GR}[ ONLINE   ✔ ]${R}        ${GR}╚════════════════╝${R}\n"
      printf "\n"
      [[ -e "$_sentinel" ]] && break; sleep 5.0
    done
  ) &
  local _anim_pid=$!

  # Wait for Enter — suppress echo so keypress is invisible
  printf "\033[${F}A\r"   # move up over the placeholder so prompt sits below animation
  printf "\n\n\n\n\n\n\n"
  printf "  \033[2m(Press Enter to continue...)\033[0m"
  local old_stty
  old_stty=$(stty -g 2>/dev/null || true)
  stty -echo 2>/dev/null || true
  read -r _pause_anim </dev/tty
  stty "$old_stty" 2>/dev/null || true

  # Signal animation to stop and wait for it to fully exit
  touch "$_sentinel"
  wait "$_anim_pid" 2>/dev/null || true
  rm -f "$_sentinel"

  # Erase the animation area completely (cursor up F+1 lines, clear to end of screen)
  printf "\033[%dA\033[J" $(( F + 1 ))
}

# ---------------------------------------------------------------------------
# Exec into the Velero pod and run: velero backup describe <name> --details
# Returns the raw output to stdout. Requires no velero binary on the host.
# ---------------------------------------------------------------------------
_velero_describe_backup() {
  local backup_name="$1"
  local velero_pod
  velero_pod=$(oc get pods -n "$VELERO_NS" -l app.kubernetes.io/name=velero \
    --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | head -1)
  if [[ -z "$velero_pod" ]]; then
    warn "No Velero pod found in '${VELERO_NS}' — cannot describe backup."
    return 1
  fi
  info "Describing backup '${backup_name}' via pod '${velero_pod}' (may take a moment)..."

  # OADP/Velero pods ship the binary at /velero; fall back to PATH if not found
  local velero_bin="/velero"
  if ! oc exec -n "$VELERO_NS" "$velero_pod" -- test -x /velero 2>/dev/null; then
    velero_bin="velero"
  fi

  local out rc=0
  out=$(oc exec -n "$VELERO_NS" "$velero_pod" -- \
    "$velero_bin" backup describe "$backup_name" --details --insecure-skip-tls-verify 2>&1) || rc=$?

  if [[ $rc -ne 0 ]]; then
    warn "velero describe exited with rc=${rc}:"
    echo "$out" >&2
    return 1
  fi
  echo "$out"
}

# ---------------------------------------------------------------------------
# Describe a completed Restore via the Velero pod — shows created/skipped counts.
# ---------------------------------------------------------------------------
_velero_describe_restore() {
  local restore_name="$1"
  local velero_pod
  velero_pod=$(oc get pods -n "$VELERO_NS" -l app.kubernetes.io/name=velero \
    --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | head -1)
  if [[ -z "$velero_pod" ]]; then
    warn "No Velero pod found — cannot describe restore."
    return 1
  fi

  local velero_bin="/velero"
  if ! oc exec -n "$VELERO_NS" "$velero_pod" -- test -x /velero 2>/dev/null; then
    velero_bin="velero"
  fi

  local out rc=0
  out=$(oc exec -n "$VELERO_NS" "$velero_pod" -- \
    "$velero_bin" restore describe "$restore_name" --details --insecure-skip-tls-verify 2>&1) || rc=$?

  if [[ $rc -ne 0 ]]; then
    warn "velero restore describe exited with rc=${rc}: ${out}"
    return 1
  fi

  # Print full output, then highlight the resource summary lines
  echo ""
  info "Restore describe: ${restore_name}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$out" | tee -a "$LOG_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Summary: extract Restored/Skipped counts from the describe output
  local restored_count skipped_count
  restored_count=$(echo "$out" | grep -oE 'Restored:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' || echo "?")
  skipped_count=$(echo "$out"  | grep -oE 'Skipped:[[:space:]]*[0-9]+'  | grep -oE '[0-9]+' || echo "?")
  if [[ "$skipped_count" != "?" && "$restored_count" != "?" ]]; then
    if [[ "$restored_count" -eq 0 && "$skipped_count" -gt 0 ]]; then
      warn "  ⚠  Restored: ${restored_count}  Skipped: ${skipped_count} — all resources were skipped (already exist?)"
    else
      ok "  ✔  Restored: ${restored_count}  Skipped: ${skipped_count}"
    fi
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Optionally describe a backup and let the user choose which resource types
# to include in the restore. Sets INCLUDE_RESOURCES (comma-separated).
# Call this after backup selection; sets the global for render_restore_yaml.
# ---------------------------------------------------------------------------
select_included_resources_interactive() {
  local backup_name="$1"
  INCLUDE_RESOURCES=""

  $NON_INTERACTIVE && return 0
  [[ -t 0 ]] || return 0

  echo ""
  read -r -p "Describe '${backup_name}' to choose specific resource types? [y/N]: " do_describe
  [[ "$do_describe" =~ ^[Yy]$ ]] || return 0

  local describe_out
  if ! describe_out=$(_velero_describe_backup "$backup_name"); then
    warn "Could not describe backup — all resource types will be restored."
    return 0
  fi

  # Extract unique resource kinds from lines like "  apps/v1/Deployment:" or "  v1/ConfigMap:"
  local kinds=()
  while IFS= read -r kind; do
    [[ -n "$kind" ]] && kinds+=("$kind")
  done < <(echo "$describe_out" | python3 -c "
import sys, re
seen = []
in_resource_list = False
for line in sys.stdin:
    if re.match(r'\s*Resource List:', line):
        in_resource_list = True
        continue
    if in_resource_list:
        # Section header ends at next non-indented or blank line outside resources
        m = re.match(r'\s{2,4}(\S+):\s*$', line)
        if m:
            # Extract just the Kind (last part after /)
            kind = m.group(1).split('/')[-1]
            if kind not in seen:
                seen.append(kind)
        elif not line.startswith(' ') and line.strip():
            in_resource_list = False
for k in seen:
    print(k)
" 2>/dev/null)

  if [[ ${#kinds[@]} -eq 0 ]]; then
    warn "Could not parse resource types from backup description — restoring all."
    echo ""
    echo "$describe_out" | head -80
    return 0
  fi

  # Show raw describe output first (paged)
  echo ""
  info "Backup description:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$describe_out"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  info "Resource types found in backup:"
  printf "  %-4s  %s\n" "#" "RESOURCE KIND"
  printf "  %-4s  %s\n" "---" "-------------------------------"
  local i
  for i in "${!kinds[@]}"; do
    printf "  %-4s  %s\n" "$((i+1))" "${kinds[$i]}"
  done
  echo ""

  local choice
  read -r -p "Select resource types to restore (e.g. '1,3', 'all', or Enter to restore all): " choice
  if [[ -z "$choice" || "$choice" == "all" ]]; then
    info "Restoring all resource types."
    return 0
  fi

  local selected_kinds=()
  local idx_list=() idx
  IFS=',' read -ra idx_list <<< "$choice"
  for idx in "${idx_list[@]}"; do
    idx="$(echo "$idx" | tr -d '[:space:]')"
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#kinds[@]} )); then
      selected_kinds+=("${kinds[$((idx-1))]}")
    else
      warn "Ignoring invalid selection: '${idx}'"
    fi
  done

  if [[ ${#selected_kinds[@]} -eq 0 ]]; then
    warn "No valid selection — restoring all resource types."
    return 0
  fi

  # Join with comma
  local IFS_ORIG="$IFS"; IFS=','
  INCLUDE_RESOURCES="${selected_kinds[*]}"
  IFS="$IFS_ORIG"
  ok "Will restore only: ${INCLUDE_RESOURCES}"
}

# ---------------------------------------------------------------------------
# Render a Restore CR as YAML for a single namespace
# ---------------------------------------------------------------------------
render_restore_yaml() {
  local ns="$1" restore_name="$2" outfile="$3" target_ns="${4:-}"

  local exclude_yaml=""
  if [[ -n "$EXCLUDE_RESOURCES" ]]; then
    exclude_yaml="  excludedResources:"$'\n'
    IFS=',' read -ra ex_list <<< "$EXCLUDE_RESOURCES"
    for r in "${ex_list[@]}"; do
      exclude_yaml+="  - ${r}"$'\n'
    done
  fi

  cat > "$outfile" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: ${VELERO_NS}
  labels:
    dr-script/run: "${TIMESTAMP}"
spec:
  backupName: ${BACKUP_NAME}
EOF
  if [[ -n "$target_ns" ]]; then
    printf '  namespaceMapping:\n    %s: %s\n' "$ns" "$target_ns" >> "$outfile"
  else
    printf '  includedNamespaces:\n  - %s\n' "$ns" >> "$outfile"
  fi
  _restorePVs_yaml_line "$BACKUP_NAME" >> "$outfile"
  if [[ -n "$INCLUDE_RESOURCES" ]]; then
    printf '  includedResources:\n' >> "$outfile"
    IFS=',' read -ra inc_list <<< "$INCLUDE_RESOURCES"
    for r in "${inc_list[@]}"; do
      printf '  - %s\n' "$r" >> "$outfile"
    done
  fi
  if [[ -n "$exclude_yaml" ]]; then
    printf '%s' "$exclude_yaml" >> "$outfile"
  fi
}

# ---------------------------------------------------------------------------
# Kick off a restore for a single namespace (oc apply -f yaml)
# ---------------------------------------------------------------------------
create_restore() {
  local ns="$1"
  local target_ns
  target_ns="$(get_ns_mapping "$ns")"
  local restore_name="${RESTORE_NAME_PREFIX}-${ns}-${TIMESTAMP}"
  local yaml_file="${YAML_DIR}/restore-${ns}.yaml"

  render_restore_yaml "$ns" "$restore_name" "$yaml_file" "$target_ns"
  info "Rendered Restore manifest: ${yaml_file}"
  cat "$yaml_file" >> "$LOG_FILE"

  if $DRY_RUN; then
    { echo ""; echo "--- Restore YAML: ${ns} ---"; cat "$yaml_file"; echo ""; } >&2
    echo "$restore_name"
    return 0
  fi

  if ! oc apply -f "$yaml_file" >>"$LOG_FILE" 2>&1; then
    error "Failed to apply Restore manifest for namespace '${ns}'. See ${LOG_FILE}."
    echo ""
    return 1
  fi

  ok "Created Restore '${restore_name}' for namespace '${ns}'."
  echo "$restore_name"
}

# ---------------------------------------------------------------------------
# Poll a restore until it completes or times out (oc get -o json)
# ---------------------------------------------------------------------------
wait_for_restore() {
  local restore_name="$1"
  local elapsed=0
  local phase=""
  local oc_rc

  if $DRY_RUN; then
    warn "[DRY RUN] Skipping wait for '${restore_name}'."
    return 0
  fi

  info "Waiting for restore '${restore_name}' (ns: ${VELERO_NS}) to complete (timeout ${RESTORE_TIMEOUT}s)..."
  while (( elapsed < RESTORE_TIMEOUT )); do
    phase=$(oc get "$RESTORE_CRD" "$restore_name" -n "$VELERO_NS" \
      -o jsonpath='{.status.phase}' 2>/dev/null)
    oc_rc=$?

    case "$phase" in
      Completed)
        ok "Restore '${restore_name}' completed successfully."
        _velero_describe_restore "$restore_name" || true
        return 0
        ;;
      WaitingForPluginOperations)
        ok "Restore '${restore_name}' completed — waiting for async plugin operations (CSI snapshots)."
        _velero_describe_restore "$restore_name" || true
        return 0
        ;;
      WaitingForPluginOperationsPartiallyFailed)
        warn "Restore '${restore_name}' WaitingForPluginOperationsPartiallyFailed. Check: oc describe ${RESTORE_CRD} ${restore_name} -n ${VELERO_NS}"
        _velero_describe_restore "$restore_name" || true
        return 2
        ;;
      PartiallyFailed)
        warn "Restore '${restore_name}' PartiallyFailed. Check: oc describe ${RESTORE_CRD} ${restore_name} -n ${VELERO_NS}"
        _velero_describe_restore "$restore_name" || true
        return 2
        ;;
      Failed)
        error "Restore '${restore_name}' Failed. Check: oc describe ${RESTORE_CRD} ${restore_name} -n ${VELERO_NS}"
        _velero_describe_restore "$restore_name" || true
        return 1
        ;;
      "")
        # Distinguish: CR not found vs CR exists but status.phase not yet set
        if oc get "$RESTORE_CRD" "$restore_name" -n "$VELERO_NS" --no-headers >/dev/null 2>&1; then
          info "  [${elapsed}s / ${RESTORE_TIMEOUT}s]  CR exists, status.phase not yet set — polling again in ${POLL_INTERVAL}s..."
        else
          if (( oc_rc != 0 )); then
            warn "  [${elapsed}s / ${RESTORE_TIMEOUT}s]  oc get failed (rc=${oc_rc}) — is '${VELERO_NS}' correct? Restore CR: ${restore_name}"
          else
            info "  [${elapsed}s / ${RESTORE_TIMEOUT}s]  Restore CR not yet found in ${VELERO_NS} — polling again in ${POLL_INTERVAL}s..."
          fi
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        ;;
      *)
        info "  [${elapsed}s / ${RESTORE_TIMEOUT}s]  phase: ${phase} — polling again in ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        ;;
    esac
  done

  error "Timed out waiting for restore '${restore_name}' after ${RESTORE_TIMEOUT}s (last phase: ${phase:-unknown})."
  return 1
}

# ---------------------------------------------------------------------------
# Post-restore validation for a namespace
# ---------------------------------------------------------------------------
validate_namespace() {
  local ns="$1"
  info "Validating namespace '${ns}' post-restore..."

  if $DRY_RUN; then
    warn "[DRY RUN] Skipping validation for '${ns}'."
    return 0
  fi

  local elapsed=0
  local not_ready=-1
  while (( elapsed < WAIT_FOR_APP_READY_TIMEOUT )); do
    not_ready=$(oc get pods -n "$ns" --no-headers 2>/dev/null | \
      awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print}' | wc -l)
    local total
    total=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [[ "$total" -gt 0 && "$not_ready" -eq 0 ]]; then
      ok "Namespace '${ns}': all ${total} pod(s) Running and ready."
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  if [[ "$not_ready" -ne 0 ]]; then
    warn "Namespace '${ns}': some pods not Running/Ready after ${WAIT_FOR_APP_READY_TIMEOUT}s. Manual check recommended."
    oc get pods -n "$ns" 2>&1 | tee -a "$LOG_FILE"
  fi

  local unbound_pvcs
  unbound_pvcs=$(oc get pvc -n "$ns" --no-headers 2>/dev/null | awk '$2!="Bound"' | wc -l)
  if [[ "$unbound_pvcs" -gt 0 ]]; then
    warn "Namespace '${ns}': ${unbound_pvcs} PVC(s) not Bound."
    oc get pvc -n "$ns" 2>&1 | tee -a "$LOG_FILE"
  else
    ok "Namespace '${ns}': all PVCs Bound (or none present)."
  fi

  if oc get routes -n "$ns" >/dev/null 2>&1; then
    local not_admitted
    not_admitted=$(oc get routes -n "$ns" -o json 2>/dev/null | \
      python3 -c 'import json,sys
d=json.load(sys.stdin)
n=0
for item in d.get("items",[]):
    ingress=item.get("status",{}).get("ingress",[])
    admitted=any(c.get("type")=="Admitted" and c.get("status")=="True" for i in ingress for c in i.get("conditions",[]))
    if not admitted:
        n+=1
print(n)' 2>/dev/null)
    if [[ "${not_admitted:-0}" -gt 0 ]]; then
      warn "Namespace '${ns}': ${not_admitted} route(s) not admitted."
    else
      ok "Namespace '${ns}': routes admitted (or none present)."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Helper: show a prereq YAML box, prompt, and optionally apply + wait
#   $1 = yaml_file path (already rendered)
#   $2 = restore_name
#   $3 = prompt description (e.g. "Namespaces / NetworkPolicies")
# ---------------------------------------------------------------------------
_apply_prereq() {
  local yaml_file="$1" restore_name="$2" description="$3"

  echo ""
  info "Prerequisite restore YAML:"
  echo "  ┌─────────────────────────────────────────────────────────────────────────────────┐"
  while IFS= read -r line; do
    printf "  │  %-81s│\n" "$line"
  done < "$yaml_file"
  echo "  └─────────────────────────────────────────────────────────────────────────────────┘"
  echo ""

  if $DRY_RUN; then
    warn "[DRY RUN] Skipping apply of '${restore_name}'."
    return 0
  fi

  if [[ -t 0 ]] && ! $NON_INTERACTIVE; then
    read -r -p "Apply prerequisite restore (${description})? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "Skipping prerequisite restore '${restore_name}'."
      return 0
    fi
  fi

  if ! oc apply -f "$yaml_file" >>"$LOG_FILE" 2>&1; then
    error "Failed to apply prerequisite restore '${restore_name}'. See ${LOG_FILE}."
    return 1
  fi
  ok "Applied prerequisite restore '${restore_name}'."

  local rc=0
  wait_for_restore "$restore_name" || rc=$?
  case $rc in
    0) ;;
    2) warn "Restore '${restore_name}' partially failed."
       if [[ -t 0 ]] && ! $NON_INTERACTIVE; then
         read -r -p "Continue to next step anyway? [y/N]: " cont
         [[ "$cont" =~ ^[Yy]$ ]] || die "Aborted by user after partial failure."
       fi ;;
    *) error "Restore '${restore_name}' failed or timed out."
       if [[ -t 0 ]] && ! $NON_INTERACTIVE; then
         read -r -p "Continue to next step anyway? [y/N]: " cont
         [[ "$cont" =~ ^[Yy]$ ]] || die "Aborted by user after restore failure."
       else
         return 1
       fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Helper: find newest backup by prefix (name must match ^prefix-\d)
# ---------------------------------------------------------------------------
_find_newest_backup() {
  local prefix="$1"
  oc get "$BACKUP_CRD" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
items = [i for i in d.get('items', [])
         if re.match(r'^${prefix}-\d', i['metadata']['name'])]
if not items:
    sys.exit(1)
newest = max(items, key=lambda x: x['metadata'].get('creationTimestamp', ''))
print(newest['metadata']['name'])
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: find newest backup whose name contains a given substring
# (Used for DB2/WCM backups whose names don't end directly with a timestamp)
# ---------------------------------------------------------------------------
_find_newest_backup_containing() {
  local pattern="$1"
  oc get "$BACKUP_CRD" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
items = [i for i in d.get('items', [])
         if re.search(r'${pattern}', i['metadata']['name'])]
if not items:
    sys.exit(1)
newest = max(items, key=lambda x: x['metadata'].get('creationTimestamp', ''))
print(newest['metadata']['name'])
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: list ALL backups whose name matches a regex, newest first
# ---------------------------------------------------------------------------
_list_backups_matching() {
  local pattern="$1"
  oc get "$BACKUP_CRD" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
items = [i for i in d.get('items', [])
         if re.search(r'${pattern}', i['metadata']['name'])]
items.sort(key=lambda x: x['metadata'].get('creationTimestamp',''), reverse=True)
for i in items:
    print(i['metadata']['name'])
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: like _list_backups_matching but returns only the newest backup per
# base name (trailing -YYYYMMDD[HHMMSS] stripped to form the group key)
# ---------------------------------------------------------------------------
_list_newest_per_base_matching() {
  local pattern="$1"
  oc get "$BACKUP_CRD" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
items = [i for i in d.get('items', [])
         if re.search(r'${pattern}', i['metadata']['name'])]
groups = {}
for item in items:
    name = item['metadata']['name']
    created = item['metadata'].get('creationTimestamp', '')
    base = re.sub(r'-\d{8}-?\d{6}$', '', name)
    if base == name:
        base = re.sub(r'-\d{8}$', '', name)
    if base not in groups or created > groups[base][1]:
        groups[base] = (name, created)
for base in sorted(groups):
    print(groups[base][0])
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: print a YAML file inside a box (used for pre-apply previews)
# ---------------------------------------------------------------------------
_show_yaml_box() {
  local yaml_file="$1"
  echo "  ┌─────────────────────────────────────────────────────────────────────────────────┐"
  while IFS= read -r line; do
    printf "  │  %-81s│\n" "$line"
  done < "$yaml_file"
  echo "  └─────────────────────────────────────────────────────────────────────────────────┘"
}

# ---------------------------------------------------------------------------
# Conditional DB2 prereq restore — lists all db2u-velero-backup* and lets user choose.
# Pre-renders all selected YAMLs and shows them before prompting to apply.
# ---------------------------------------------------------------------------
_restore_db2_prereq() {
  info "Checking for DB2 backups (db2u-velero-backup*)..."

  local raw
  raw=$(_list_newest_per_base_matching "db2u-velero-backup") || true
  if [[ -z "$raw" ]]; then
    info "No DB2 backups found — skipping."
    return 0
  fi

  local names=()
  while IFS= read -r name; do [[ -n "$name" ]] && names+=("$name"); done <<< "$raw"

  echo "" | tee -a "$LOG_FILE"
  printf "  %-4s  %s\n" "#" "DB2 BACKUP NAME" | tee -a "$LOG_FILE"
  printf "  %-4s  %s\n" "---" "----------------------------------------------------------------------" | tee -a "$LOG_FILE"
  local i
  for i in "${!names[@]}"; do
    printf "  %-4s  %s\n" "$((i+1))" "${names[$i]}" | tee -a "$LOG_FILE"
  done
  echo ""

  if $NON_INTERACTIVE || ! [[ -t 0 ]]; then
    info "Non-interactive — skipping DB2 restore selection."
    return 0
  fi

  local choice
  read -r -p "Select DB2 backup(s) to restore (e.g. '1' or '1,2' or 'all', Enter to skip): " choice
  [[ -z "$choice" ]] && { info "Skipping DB2 restore."; return 0; }

  local selected=()
  if [[ "$choice" == "all" ]]; then
    selected=("${names[@]}")
  else
    local idx_list=() idx
    IFS=',' read -ra idx_list <<< "$choice"
    for idx in "${idx_list[@]}"; do
      idx="$(echo "$idx" | tr -d '[:space:]')"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#names[@]} )); then
        selected+=("${names[$((idx-1))]}")
      else
        warn "Ignoring invalid selection: '${idx}'"
      fi
    done
  fi
  [[ ${#selected[@]} -eq 0 ]] && { info "No valid DB2 backups selected — skipping."; return 0; }

  # Pre-render all restore YAMLs
  local yaml_files=() restore_names=() ns_arr=()
  local backup db2_ns ts yaml_file restore_name
  for backup in "${selected[@]}"; do
    db2_ns=$(oc get "$BACKUP_CRD" "$backup" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
ns=[n for n in d.get("spec",{}).get("includedNamespaces",[]) if n and n!="*"]
print(ns[0] if ns else "ose-db2-bd")
' 2>/dev/null)
    db2_ns="${db2_ns:-ose-db2-bd}"
    prompt_ns_mapping_single "$db2_ns"
    ts=$(echo "$backup" | grep -oE '[0-9]{8}[0-9]*$' || echo "$TIMESTAMP")
    restore_name="restore-db2-${db2_ns}-${ts}"
    yaml_file="${YAML_DIR}/prereq-db2-${db2_ns}.yaml"
    cat > "$yaml_file" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup}
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
    - ${db2_ns}
$(_restorePVs_yaml_line "$backup")
EOF
    append_ns_mapping_to_yaml "$yaml_file" "$db2_ns"
    yaml_files+=("$yaml_file")
    restore_names+=("$restore_name")
    ns_arr+=("$db2_ns")
  done

  # Show all YAMLs before prompting
  echo "" | tee -a "$LOG_FILE"
  info "DB2 Restore YAML(s) to be applied:"
  for i in "${!yaml_files[@]}"; do
    echo ""
    info "  → ${restore_names[$i]}  [${ns_arr[$i]}]"
    _show_yaml_box "${yaml_files[$i]}"
    cat "${yaml_files[$i]}" >> "$LOG_FILE"
  done
  echo ""

  if $DRY_RUN; then
    warn "[DRY RUN] Manifests saved to ${YAML_DIR} — not applied."
    return 0
  fi

  read -r -p "Apply DB2 restore(s) above? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Skipping DB2 restore(s)."; return 0; }

  for i in "${!restore_names[@]}"; do
    if ! oc apply -f "${yaml_files[$i]}" >>"$LOG_FILE" 2>&1; then
      error "Failed to apply '${restore_names[$i]}'."
      read -r -p "Continue to next DB2 restore? [y/N]: " cont
      [[ "$cont" =~ ^[Yy]$ ]] || return 1
      continue
    fi
    ok "Applied '${restore_names[$i]}'."
    local rc=0
    wait_for_restore "${restore_names[$i]}" || rc=$?
    case $rc in
      0) ;;
      2) warn "Restore '${restore_names[$i]}' partially failed."
         read -r -p "Continue to next DB2 restore? [y/N]: " cont
         [[ "$cont" =~ ^[Yy]$ ]] || return 0 ;;
      *) error "Restore '${restore_names[$i]}' failed or timed out."
         read -r -p "Continue to next DB2 restore? [y/N]: " cont
         [[ "$cont" =~ ^[Yy]$ ]] || return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Prereq: restore all dxo-velero-backup-all-crds-* workloads (WCM, MEP, EBA, …).
# Auto-discovers every all-crds backup (newest per base name), lets user select,
# then pairs each with a matching pvc-only backup for Phase B.
# Pre-renders ALL phase YAMLs and shows them before prompting to apply.
# Must complete before ArgoCD restores — otherwise ArgoCD recreates PVCs from scratch.
# ---------------------------------------------------------------------------
_restore_wcm_prereq() {
  info "Checking for all-crds backups (dxo-velero-backup-all-crds-*)..."

  local raw_allcrds raw_pvconly
  raw_allcrds=$(_list_newest_per_base_matching "dxo-velero-backup-all-crds-") || true
  raw_pvconly=$(_list_newest_per_base_matching "dxo-velero-backup-pvc-only-") || true

  if [[ -z "$raw_allcrds" && -z "$raw_pvconly" ]]; then
    info "No all-crds/pvc-only backups found — skipping."
    return 0
  fi

  local allcrds_names=() pvconly_names=()
  while IFS= read -r name; do [[ -n "$name" ]] && allcrds_names+=("$name"); done <<< "$raw_allcrds"
  while IFS= read -r name; do [[ -n "$name" ]] && pvconly_names+=("$name"); done <<< "$raw_pvconly"

  # --- Select all-crds backups ---
  echo "" | tee -a "$LOG_FILE"
  info "Available all-crds backups (WCM / MEP / EBA / …):"
  printf "  %-4s  %s\n" "#" "BACKUP NAME (all-crds)" | tee -a "$LOG_FILE"
  printf "  %-4s  %s\n" "---" "----------------------------------------------------------------------" | tee -a "$LOG_FILE"
  local i
  for i in "${!allcrds_names[@]}"; do
    printf "  %-4s  %s\n" "$((i+1))" "${allcrds_names[$i]}" | tee -a "$LOG_FILE"
  done
  echo ""

  if $NON_INTERACTIVE || ! [[ -t 0 ]]; then
    info "Non-interactive — skipping all-crds restore selection."
    return 0
  fi

  local choice
  read -r -p "Select all-crds backup(s) to restore (e.g. '1' or '1,2' or 'all', Enter to skip): " choice
  [[ -z "$choice" ]] && { info "Skipping all-crds restores."; return 0; }

  local selected_allcrds=()
  if [[ "$choice" == "all" ]]; then
    selected_allcrds=("${allcrds_names[@]}")
  else
    local idx_list=() idx
    IFS=',' read -ra idx_list <<< "$choice"
    for idx in "${idx_list[@]}"; do
      idx="$(echo "$idx" | tr -d '[:space:]')"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#allcrds_names[@]} )); then
        selected_allcrds+=("${allcrds_names[$((idx-1))]}")
      else
        warn "Ignoring invalid selection: '${idx}'"
      fi
    done
  fi
  [[ ${#selected_allcrds[@]} -eq 0 ]] && { info "No valid all-crds backups selected — skipping."; return 0; }

  # --- Select pvc-only backups ---
  local selected_pvconly=()
  if [[ ${#pvconly_names[@]} -gt 0 ]]; then
    echo "" | tee -a "$LOG_FILE"
    info "Available pvc-only backups (Phase B):"
    printf "  %-4s  %s\n" "#" "BACKUP NAME (pvc-only)" | tee -a "$LOG_FILE"
    printf "  %-4s  %s\n" "---" "----------------------------------------------------------------------" | tee -a "$LOG_FILE"
    for i in "${!pvconly_names[@]}"; do
      printf "  %-4s  %s\n" "$((i+1))" "${pvconly_names[$i]}" | tee -a "$LOG_FILE"
    done
    echo ""
    read -r -p "Select pvc-only backup(s) for Phase B (e.g. '1' or '1,2' or 'all', Enter to skip Phase B): " choice
    if [[ -n "$choice" ]]; then
      if [[ "$choice" == "all" ]]; then
        selected_pvconly=("${pvconly_names[@]}")
      else
        IFS=',' read -ra idx_list <<< "$choice"
        for idx in "${idx_list[@]}"; do
          idx="$(echo "$idx" | tr -d '[:space:]')"
          if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#pvconly_names[@]} )); then
            selected_pvconly+=("${pvconly_names[$((idx-1))]}")
          else
            warn "Ignoring invalid pvc-only selection: '${idx}'"
          fi
        done
      fi
    fi
    [[ ${#selected_pvconly[@]} -eq 0 ]] && warn "No pvc-only backups selected — Phase B will be skipped."
  else
    warn "No pvc-only backups found — Phase B will be skipped."
  fi

  # Pre-render ALL phase YAMLs for ALL selected backups
  local all_yaml_files=() all_restore_names=() all_phase_labels=()
  local backup_allcrds backup_pvconly wcm_ns ts suffix bk_prefix

  for backup_allcrds in "${selected_allcrds[@]}"; do
    suffix="${backup_allcrds#dxo-velero-backup-all-crds-}"
    ts=$(echo "$backup_allcrds" | grep -oE '[0-9]{8}[0-9]*$' || echo "$TIMESTAMP")
    bk_prefix=$(echo "$suffix" | cut -d'-' -f1)   # e.g. "mep" or "wcm"

    # Match pvc-only from selected list by suffix; fall back to first selected
    backup_pvconly=""
    for pvc in "${selected_pvconly[@]}"; do
      [[ "${pvc#dxo-velero-backup-pvc-only-}" == "$suffix" ]] && { backup_pvconly="$pvc"; break; }
    done
    [[ -z "$backup_pvconly" && ${#selected_pvconly[@]} -gt 0 ]] && backup_pvconly="${selected_pvconly[0]}"

    wcm_ns=$(oc get "$BACKUP_CRD" "$backup_allcrds" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
ns=[n for n in d.get("spec",{}).get("includedNamespaces",[]) if n and n!="*"]
print(ns[0] if ns else "")
' 2>/dev/null)
    [[ -z "$wcm_ns" ]] && wcm_ns=$(echo "$suffix" | sed 's/-[0-9]\{8\}[0-9]*$//')

    prompt_ns_mapping_single "$wcm_ns"

    # Phase A: ClusterRole + ServiceAccount
    local yaml_a; yaml_a="${YAML_DIR}/prereq-wcm-${wcm_ns}-a-sa.yaml"
    cat > "$yaml_a" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restore-${bk_prefix}-sa-${wcm_ns}-${ts}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup_allcrds}
  excludedResources:
    - imagestreams
    - nodes
    - events
    - events.events.k8s.io
    - backups.velero.io
    - restores.velero.io
    - resticrepositories.velero.io
    - csinodes.storage.k8s.io
    - volumeattachments.storage.k8s.io
  includedResources:
    - ClusterRole
    - ServiceAccount
  includedNamespaces:
    - ${wcm_ns}
EOF
    append_ns_mapping_to_yaml "$yaml_a" "$wcm_ns"
    all_yaml_files+=("$yaml_a")
    all_restore_names+=("restore-${bk_prefix}-sa-${wcm_ns}-${ts}")
    all_phase_labels+=("${wcm_ns} Phase A: ClusterRole / ServiceAccount")

    # Phase B: PVCs only
    if [[ -n "$backup_pvconly" ]]; then
      local yaml_b; yaml_b="${YAML_DIR}/prereq-wcm-${wcm_ns}-b-pvc.yaml"
      cat > "$yaml_b" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restore-${bk_prefix}-pvc-${wcm_ns}-${ts}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup_pvconly}
  excludedResources:
    - imagestreams
    - nodes
    - events
    - events.events.k8s.io
    - backups.velero.io
    - restores.velero.io
    - resticrepositories.velero.io
    - csinodes.storage.k8s.io
    - volumeattachments.storage.k8s.io
  includedNamespaces:
    - ${wcm_ns}
$(_restorePVs_yaml_line "$backup_pvconly")
EOF
      append_ns_mapping_to_yaml "$yaml_b" "$wcm_ns"
      all_yaml_files+=("$yaml_b")
      all_restore_names+=("restore-${bk_prefix}-pvc-${wcm_ns}-${ts}")
      all_phase_labels+=("${wcm_ns} Phase B: PVCs")
    else
      warn "No matching pvc-only backup for '${backup_allcrds}' — Phase B will be skipped."
    fi
  done

  # Show ALL phase YAMLs before any prompt
  echo "" | tee -a "$LOG_FILE"
  info "All-crds/PVC-only Restore YAML(s) to be applied (in order):"
  for i in "${!all_yaml_files[@]}"; do
    echo ""
    info "  → ${all_restore_names[$i]}  [${all_phase_labels[$i]}]"
    _show_yaml_box "${all_yaml_files[$i]}"
    cat "${all_yaml_files[$i]}" >> "$LOG_FILE"
  done
  echo ""

  if $DRY_RUN; then
    warn "[DRY RUN] Manifests saved to ${YAML_DIR} — not applied."
    return 0
  fi

  read -r -p "Apply all-crds/pvc-only restore(s) above (phases run in order A→B)? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Skipping all-crds/pvc-only restore(s)."; return 0; }

  # Apply sequentially — each phase must complete before the next
  for i in "${!all_restore_names[@]}"; do
    if ! oc apply -f "${all_yaml_files[$i]}" >>"$LOG_FILE" 2>&1; then
      error "Failed to apply '${all_restore_names[$i]}'."
      read -r -p "Continue to next phase? [y/N]: " cont
      [[ "$cont" =~ ^[Yy]$ ]] || return 1
      continue
    fi
    ok "Applied '${all_restore_names[$i]}'."
    local rc=0
    wait_for_restore "${all_restore_names[$i]}" || rc=$?
    case $rc in
      0) ;;
      2) warn "Restore '${all_restore_names[$i]}' partially failed."
         read -r -p "Continue to next phase? [y/N]: " cont
         [[ "$cont" =~ ^[Yy]$ ]] || return 0 ;;
      *) error "Restore '${all_restore_names[$i]}' failed or timed out."
         read -r -p "Continue to next phase? [y/N]: " cont
         [[ "$cont" =~ ^[Yy]$ ]] || return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# List ArgoCD AppProjects and Applications in a namespace (used before/after restore)
# ---------------------------------------------------------------------------
_list_argocd_resources() {
  local ns="$1" label="$2"
  echo "" | tee -a "$LOG_FILE"
  info "--- ArgoCD resources in '${ns}' ${label} ---"

  if ! oc get ns "$ns" >/dev/null 2>&1; then
    info "  Namespace '${ns}' does not exist yet."
    return 0
  fi

  local projects
  projects=$(oc get appproject.argoproj.io -n "$ns" \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
  info "  AppProjects:"
  if [[ -n "$projects" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && printf "    %-40s\n" "$p" | tee -a "$LOG_FILE"
    done <<< "$projects"
  else
    echo "    (none)" | tee -a "$LOG_FILE"
  fi

  local apps
  apps=$(oc get application.argoproj.io -n "$ns" \
    --no-headers -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    2>/dev/null || true)
  info "  Applications:"
  if [[ -n "$apps" ]]; then
    while IFS= read -r a; do
      [[ -n "$a" ]] && printf "    %-50s\n" "$a" | tee -a "$LOG_FILE"
    done <<< "$apps"
  else
    echo "    (none)" | tee -a "$LOG_FILE"
  fi

  local secrets_json
  secrets_json=$(oc get secrets -n "$ns" -l argocd.argoproj.io/secret-type \
    -o json 2>/dev/null || true)
  info "  Secrets (argocd.argoproj.io/secret-type):"
  if [[ -z "$secrets_json" ]]; then
    echo "    (none)" | tee -a "$LOG_FILE"
  else
    ARGOCD_SECRETS_JSON="$secrets_json" python3 -c '
import json, base64, os

SENSITIVE = {"password","sshPrivateKey","bearerToken","token",
             "tlsClientCertData","tlsClientCertKey","clientSecret"}

data = json.loads(os.environ["ARGOCD_SECRETS_JSON"])
items = data.get("items", [])
if not items:
    print("    (none)")
for secret in items:
    name  = secret["metadata"]["name"]
    stype = secret["metadata"].get("labels", {}).get("argocd.argoproj.io/secret-type", "?")
    raw   = secret.get("data", {})
    decoded = {}
    for k, v in raw.items():
        try:    decoded[k] = base64.b64decode(v).decode("utf-8").strip()
        except: decoded[k] = v
    print("    \u250c\u2500 %s  [%s]" % (name, stype))
    order = ["name","server","url","type","project","username",
             "insecure","tlsClientCertData","password","sshPrivateKey","bearerToken","token"]
    shown = set()
    for k in order:
        if k in decoded:
            val = "***masked***" if k in SENSITIVE else decoded[k]
            print("    \u2502  %-22s %s" % (k, val))
            shown.add(k)
    for k, v in decoded.items():
        if k not in shown:
            val = "***masked***" if k in SENSITIVE else v
            print("    \u2502  %-22s %s" % (k, val))
    print("    \u2514" + "\u2500" * 40)
' 2>&1 | tee -a "$LOG_FILE"
  fi
  echo "" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Prereq: restore all *gitops* backups (newest per base name). Lists available
# backups, lets user select one at a time, loops until done.
# ---------------------------------------------------------------------------
_restore_gitops_prereq() {
  info "Checking for ArgoCD gitops backups (*gitops*)..."

  local raw
  raw=$(_list_newest_per_base_matching "gitops") || true
  if [[ -z "$raw" ]]; then
    info "No gitops backups found — skipping."
    return 0
  fi

  local all_names=()
  while IFS= read -r name; do [[ -n "$name" ]] && all_names+=("$name"); done <<< "$raw"

  if $NON_INTERACTIVE || ! [[ -t 0 ]]; then
    info "Non-interactive — skipping gitops restore selection."
    return 0
  fi

  # Track which backups have already been restored this session
  local restored=()
  local idx_g=0

  while true; do
    # Build remaining list (exclude already restored)
    local remaining=()
    local b
    for b in "${all_names[@]}"; do
      local done=false
      local r
      for r in "${restored[@]:-}"; do [[ "$r" == "$b" ]] && done=true && break; done
      $done || remaining+=("$b")
    done

    [[ ${#remaining[@]} -eq 0 ]] && { info "All gitops backups have been restored."; return 0; }

    echo "" | tee -a "$LOG_FILE"
    info "Available gitops backups:"
    printf "  %-4s  %s\n" "#" "GITOPS BACKUP NAME" | tee -a "$LOG_FILE"
    printf "  %-4s  %s\n" "---" "----------------------------------------------------------------------" | tee -a "$LOG_FILE"
    local i
    for i in "${!remaining[@]}"; do
      printf "  %-4s  %s\n" "$((i+1))" "${remaining[$i]}" | tee -a "$LOG_FILE"
    done
    echo ""

    local choice
    read -r -p "Select gitops backup(s) to restore (e.g. '1' or '1,2' or 'all', Enter to skip/done): " choice
    [[ -z "$choice" ]] && { info "Done with gitops restores."; return 0; }

    local selected=()
    if [[ "$choice" == "all" ]]; then
      selected=("${remaining[@]}")
    else
      local idx_list=() idx
      IFS=',' read -ra idx_list <<< "$choice"
      for idx in "${idx_list[@]}"; do
        idx="$(echo "$idx" | tr -d '[:space:]')"
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#remaining[@]} )); then
          selected+=("${remaining[$((idx-1))]}")
        else
          warn "Ignoring invalid selection: '${idx}'"
        fi
      done
    fi
    [[ ${#selected[@]} -eq 0 ]] && { warn "No valid selection — try again."; continue; }

    # Sort selected by dependency order
    local sorted_selected=()
    for b in "${selected[@]}"; do [[ "$b" == *openshift-gitops* ]] && sorted_selected+=("$b"); done
    for b in "${selected[@]}"; do [[ "$b" == *ose-gitops-hub*   ]] && sorted_selected+=("$b"); done
    for b in "${selected[@]}"; do [[ "$b" == *ose-gitops-ahx*   ]] && sorted_selected+=("$b"); done
    for b in "${selected[@]}"; do [[ "$b" == *-bd-* || "$b" == *-bd ]] && sorted_selected+=("$b"); done
    for b in "${selected[@]}"; do
      [[ "$b" == *openshift-gitops* || "$b" == *ose-gitops-hub* || "$b" == *ose-gitops-ahx* ]] && continue
      [[ "$b" == *-bd-* || "$b" == *-bd ]] && continue
      sorted_selected+=("$b")
    done

    # Restore each selected backup in order
    local backup gitops_ns ts yaml_file restore_name
    for backup in "${sorted_selected[@]}"; do
      gitops_ns=$(oc get "$BACKUP_CRD" "$backup" -n "$VELERO_NS" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
ns=[n for n in d.get("spec",{}).get("includedNamespaces",[]) if n and n!="*"]
print(ns[0] if ns else "")
' 2>/dev/null)
      if [[ -z "$gitops_ns" ]]; then
        gitops_ns=$(echo "$backup" | sed 's/-[0-9]\{8\}[0-9]*$//' | sed 's/^.*-\(ose-[^-].*\)$/\1/')
        [[ -z "$gitops_ns" ]] && gitops_ns="$backup"
      fi
      ts=$(echo "$backup" | grep -oE '[0-9]{8}[0-9]*$' || echo "$TIMESTAMP")
      restore_name="restore-gitops-${gitops_ns}-${ts}"
      yaml_file="${YAML_DIR}/prereq-gitops-${idx_g}-${gitops_ns}.yaml"
      idx_g=$((idx_g + 1))

      prompt_ns_mapping_single "$gitops_ns"

      cat > "$yaml_file" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup}
  includedResources:
    - AppProject
    - Application
    - Secret
  includedNamespaces:
    - ${gitops_ns}
EOF
      append_ns_mapping_to_yaml "$yaml_file" "$gitops_ns"

      local effective_gitops_ns
      effective_gitops_ns="$(get_ns_mapping "$gitops_ns")"
      effective_gitops_ns="${effective_gitops_ns:-$gitops_ns}"
      _list_argocd_resources "$effective_gitops_ns" "(before restore)"
      _apply_prereq "$yaml_file" "$restore_name" "AppProjects / Applications (${gitops_ns})"
      _list_argocd_resources "$effective_gitops_ns" "(after restore)"

      restored+=("$backup")
    done

    # Ask to continue only if there are remaining backups
    local still_remaining=0
    for b in "${all_names[@]}"; do
      local done=false
      local r
      for r in "${restored[@]}"; do [[ "$r" == "$b" ]] && done=true && break; done
      $done || still_remaining=$((still_remaining + 1))
    done
    [[ $still_remaining -eq 0 ]] && { info "All gitops backups have been restored."; return 0; }

    echo ""
    read -r -p "Restore another gitops backup? [y/N]: " again
    [[ "$again" =~ ^[Yy]$ ]] || { info "Done with gitops restores."; return 0; }
  done
}
# ORDER MATTERS: stateful workloads (DB2, WCM) must be restored BEFORE ArgoCD
# restores AppProjects/Applications — otherwise ArgoCD recreates PVCs from scratch.
# ---------------------------------------------------------------------------
run_prereq_restores() {
  info "--- Prerequisite Restores ---"

  # Step 1. Namespaces / NetworkPolicies / EgressFirewalls from bankdata-resources
  local backup ts yaml_file restore_name
  backup=$(_find_newest_backup "ose-infrastructure-backup-bankdata-resources")
  if [[ -z "$backup" ]]; then
    warn "No backup matching 'ose-infrastructure-backup-bankdata-resources*' found — skipping."
  else
    ok "Found prereq backup: ${backup}"
    ts=$(echo "$backup" | grep -oE '[0-9]{8}[0-9]*$')
    restore_name="restore-bd-ns-crds-${ts}"
    yaml_file="${YAML_DIR}/prereq-1-bankdata-resources.yaml"
    cat > "$yaml_file" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup}
  includedResources:
    - Namespace
    - NetworkPolicy
    - EgressFirewall
  includedNamespaces:
    - "*"
EOF
    _apply_prereq "$yaml_file" "$restore_name" "Namespaces / NetworkPolicies / EgressFirewalls"
  fi

  # Step 2. DB2 StatefulSets + PVCs (conditional — only if db2u-velero-backup* found)
  _restore_db2_prereq

  # Step 3. All-crds workloads (WCM / MEP / EBA / …) — auto-discovers all dxo-velero-backup-all-crds-*
  _restore_wcm_prereq

  # Step 5. Sealed Secrets — must be in place before ArgoCD pulls SealedSecrets from Git
  backup=$(_find_newest_backup "ose-infrastructure-backup-ose-sealed-secrets")
  if [[ -z "$backup" ]]; then
    warn "No backup matching 'ose-infrastructure-backup-ose-sealed-secrets*' found — skipping."
  else
    ok "Found prereq backup: ${backup}"
    ts=$(echo "$backup" | grep -oE '[0-9]{8}[0-9]*$')
    restore_name="restore-sealed-secrets-${ts}"
    yaml_file="${YAML_DIR}/prereq-5-ose-sealed-secrets.yaml"
    cat > "$yaml_file" <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: ${VELERO_NS}
spec:
  backupName: ${backup}
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
EOF
    prompt_ns_mapping_single "ose-sealed-secrets"
    append_ns_mapping_to_yaml "$yaml_file" "ose-sealed-secrets"
    _apply_prereq "$yaml_file" "$restore_name" "Sealed Secrets (ose-sealed-secrets)"
  fi

  # Step 6 & 7. AppProjects / Applications — all *gitops* backups (newest per base name)
  _restore_gitops_prereq

  # Step 8. Optional: patch ArgoCD destinations for disaster-cluster (different API server URL)
  patch_argocd_destinations
}

# ---------------------------------------------------------------------------
# Optional: patch ArgoCD Application/AppProject spec.destinations server URL.
# Needed when restoring to a disaster cluster whose API URL differs from the source.
# The README notes: use spec.destinations.name instead of .server to avoid this issue
# permanently; but this patch handles it when .server was used on the source cluster.
# ---------------------------------------------------------------------------
patch_argocd_destinations() {
  [[ -t 0 ]] && ! $NON_INTERACTIVE || return 0
  echo ""
  local current_url
  current_url=$(oc whoami --show-server 2>/dev/null)
  info "Current cluster API server: ${current_url:-unknown}"
  read -r -p "Patch ArgoCD spec.destinations server URL? (needed when API URL differs from source cluster) [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0

  # Detect new (DR) server URL — done once outside the loop
  local new_server="$current_url"
  if [[ -z "$new_server" ]]; then
    warn "Could not detect current cluster URL via 'oc whoami --show-server'."
    read -r -p "  Enter new (DR) server URL manually: " new_server
    [[ -z "$new_server" ]] && { warn "No URL entered — skipping patch."; return 0; }
  else
    info "Detected current (DR) cluster URL: ${new_server}"
    read -r -p "  Use this as the new server URL? [Y/n]: " yn
    if [[ "$yn" =~ ^[Nn]$ ]]; then
      read -r -p "  Enter new (DR) server URL: " new_server
      [[ -z "$new_server" ]] && { warn "No URL entered — skipping patch."; return 0; }
    fi
  fi

  # Discover all *gitops* namespaces once
  local all_gitops_ns=()
  while IFS= read -r ns; do
    [[ -n "$ns" ]] && all_gitops_ns+=("$ns")
  done < <(oc get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -i gitops || true)

  if [[ ${#all_gitops_ns[@]} -eq 0 ]]; then
    warn "No *gitops* namespaces found on cluster — skipping."
    return 0
  fi

  # Main loop: pick namespace(s) → scan → patch → repeat or quit
  while true; do
    # --- 1. Namespace selection ---
    local selected_ns=()
    if [[ ${#all_gitops_ns[@]} -eq 1 ]]; then
      selected_ns=("${all_gitops_ns[0]}")
      info "Using gitops namespace: ${selected_ns[0]}"
    else
      echo ""
      info "GitOps namespaces found on cluster:"
      printf "  %-4s  %s\n" "#" "NAMESPACE"
      printf "  %-4s  %s\n" "---" "----------------------------------------"
      local i
      for i in "${!all_gitops_ns[@]}"; do
        printf "  %-4s  %s\n" "$((i+1))" "${all_gitops_ns[$i]}"
      done
      echo ""
      local choice
      read -r -p "Select namespace(s) to patch (e.g. '1,2' or 'all', default all, 'q' to quit): " choice
      [[ "$choice" =~ ^[Qq](uit)?$ ]] && { info "Exiting ArgoCD destination patch."; return 0; }
      [[ -z "$choice" ]] && choice="all"
      if [[ "$choice" == "all" ]]; then
        selected_ns=("${all_gitops_ns[@]}")
      else
        local idx_list=() idx
        IFS=',' read -ra idx_list <<< "$choice"
        for idx in "${idx_list[@]}"; do
          idx="$(echo "$idx" | tr -d '[:space:]')"
          if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#all_gitops_ns[@]} )); then
            selected_ns+=("${all_gitops_ns[$((idx-1))]}")
          else
            warn "Ignoring invalid selection: '${idx}'"
          fi
        done
        if [[ ${#selected_ns[@]} -eq 0 ]]; then
          warn "No valid namespace selected — try again."
          continue
        fi
      fi
    fi

    # --- 2. Scan selected namespaces for server URLs ---
    local found_servers=()
    local gns
    for gns in "${selected_ns[@]}"; do
      info "Scanning Applications in '${gns}'..."
      local app_count
      app_count=$(oc get application.argoproj.io -n "$gns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
      info "  Found ${app_count} Application(s) — destination summary:"
      oc get application.argoproj.io -n "$gns" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for item in d.get('items',[]):
    name=item['metadata']['name']
    dest=item.get('spec',{}).get('destination',{})
    server=dest.get('server','')
    dname=dest.get('name','')
    ns=dest.get('namespace','')
    print('  %-45s server=%-45s name=%-20s ns=%s' % (name, server or '(not set)', dname or '(not set)', ns))
" 2>/dev/null | tee -a "$LOG_FILE" || warn "  Could not read destinations."
      echo ""

      local srv_line
      while IFS= read -r srv_line; do
        [[ -z "$srv_line" ]] && continue
        local already=false
        local fs
        for fs in "${found_servers[@]:-}"; do [[ "$fs" == "$srv_line" ]] && already=true && break; done
        $already || found_servers+=("$srv_line")
      done < <(oc get application.argoproj.io -n "$gns" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
seen=set()
for item in d.get('items',[]):
    s=item.get('spec',{}).get('destination',{}).get('server','')
    if s and s not in seen:
        seen.add(s); print(s)
" 2>/dev/null || true)
    done

    # --- 3. Determine old server URL ---
    local old_candidates=()
    local fs
    for fs in "${found_servers[@]:-}"; do
      [[ "$fs" != "$new_server" ]] && old_candidates+=("$fs")
    done

    local old_server=""
    if [[ ${#old_candidates[@]} -eq 1 ]]; then
      info "Detected source cluster URL in ArgoCD destinations: ${old_candidates[0]}"
      read -r -p "  Use this as the old server URL to replace? [Y/n]: " yn
      if [[ "$yn" =~ ^[Nn]$ ]]; then
        read -r -p "  Enter old (source) server URL: " old_server
      else
        old_server="${old_candidates[0]}"
      fi
    elif [[ ${#old_candidates[@]} -gt 1 ]]; then
      info "Multiple server URLs found in ArgoCD destinations:"
      local ii
      for ii in "${!old_candidates[@]}"; do
        printf "  %s) %s\n" "$((ii+1))" "${old_candidates[$ii]}"
      done
      read -r -p "  Select old server URL by number (or type manually): " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#old_candidates[@]} )); then
        old_server="${old_candidates[$((choice-1))]}"
      else
        old_server="$choice"
      fi
    elif [[ ${#found_servers[@]} -gt 0 ]]; then
      ok "All Applications already point to '${new_server}' — no patching needed for selected namespace(s)."
      old_server=""
    else
      warn "No spec.destination.server found — apps may use spec.destination.name (no patch needed)."
      read -r -p "  Enter old (source) server URL manually if needed [Enter to skip]: " old_server
    fi

    if [[ -z "$old_server" ]]; then
      info "No old server URL — skipping patch for this selection."
    else
      info "Replacing: ${old_server}  →  ${new_server}"

      # --- 4. Build patch list ---
      local -a p_display=() p_app_ns=() p_app_name=() p_kind=()
      for gns in "${selected_ns[@]}"; do
        local app_name
        while IFS= read -r app_name; do
          [[ -z "$app_name" ]] && continue
          local cur_server
          cur_server=$(oc get application.argoproj.io "$app_name" -n "$gns" \
            -o jsonpath='{.spec.destination.server}' 2>/dev/null || true)
          [[ "$cur_server" == "$old_server" ]] || continue
          p_display+=("Application/${app_name} -n ${gns}")
          p_app_ns+=("$gns"); p_app_name+=("$app_name"); p_kind+=("application")
        done < <(oc get application.argoproj.io -n "$gns" --no-headers \
                   -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

        local proj_name
        while IFS= read -r proj_name; do
          [[ -z "$proj_name" || "$proj_name" == "default" ]] && continue
          local has_old
          has_old=$(oc get appproject.argoproj.io "$proj_name" -n "$gns" -o json 2>/dev/null | \
            python3 -c "
import json,sys
d=json.load(sys.stdin)
dests=d.get('spec',{}).get('destinations',[])
print('yes' if any(dest.get('server','')=='${old_server}' for dest in dests) else '')
" 2>/dev/null || true)
          [[ "$has_old" == "yes" ]] || continue
          p_display+=("AppProject/${proj_name} -n ${gns}")
          p_app_ns+=("$gns"); p_app_name+=("$proj_name"); p_kind+=("appproject")
        done < <(oc get appproject.argoproj.io -n "$gns" --no-headers \
                   -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
      done

      if [[ ${#p_display[@]} -eq 0 ]]; then
        warn "No Applications or AppProjects found with server '${old_server}' — nothing to patch."
      else
        # --- 5. Show each patch with BEFORE, prompt run/skip/all ---
        echo ""
        info "${#p_display[@]} resource(s) to patch — review each command:"
        local patched=0 failed=0 skipped=0
        local j
        for j in "${!p_display[@]}"; do
          local pns="${p_app_ns[$j]}" pname="${p_app_name[$j]}" pkind="${p_kind[$j]}"
          echo ""
          if [[ "$pkind" == "application" ]]; then
            local bsrv bns bname
            bsrv=$(oc get application.argoproj.io "$pname" -n "$pns" -o jsonpath='{.spec.destination.server}' 2>/dev/null || echo "(unknown)")
            bns=$(oc get application.argoproj.io "$pname" -n "$pns" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)
            bname=$(oc get application.argoproj.io "$pname" -n "$pns" -o jsonpath='{.spec.destination.name}' 2>/dev/null || true)
            echo "  ┌─── BEFORE: Application/${pname} -n ${pns} $(printf '%0.s─' {1..20})┐"
            printf "  │  %-77s│\n" "spec.destination.server:    ${bsrv}"
            [[ -n "$bns" ]]   && printf "  │  %-77s│\n" "spec.destination.namespace: ${bns}"
            [[ -n "$bname" ]] && printf "  │  %-77s│\n" "spec.destination.name:      ${bname}"
            echo "  ├─── PATCH ──────────────────────────────────────────────────────────────────┤"
            printf "  │  %-77s│\n" "oc patch application.argoproj.io ${pname} -n ${pns} \\"
            printf "  │  %-77s│\n" "   --type=json -p '[{\"op\":\"replace\","
            printf "  │  %-77s│\n" "   \"path\":\"/spec/destination/server\","
            printf "  │  %-77s│\n" "   \"value\":\"${new_server}\"}]'"
            echo "  └─────────────────────────────────────────────────────────────────────────────┘"
          else
            local bdests
            bdests=$(oc get appproject.argoproj.io "$pname" -n "$pns" -o json 2>/dev/null | \
              python3 -c "
import json,sys
d=json.load(sys.stdin)
for dest in d.get('spec',{}).get('destinations',[]):
    print('  server=%-55s namespace=%s' % (dest.get('server',''),dest.get('namespace','')))
" 2>/dev/null || echo "  (unknown)")
            echo "  ┌─── BEFORE: AppProject/${pname} -n ${pns} $(printf '%0.s─' {1..20})┐"
            while IFS= read -r line; do printf "  │  %-77s│\n" "$line"; done <<< "$bdests"
            echo "  ├─── PATCH ──────────────────────────────────────────────────────────────────┤"
            printf "  │  %-77s│\n" "oc patch appproject.argoproj.io ${pname} -n ${pns} \\"
            printf "  │  %-77s│\n" "   --type=merge (replace server '${old_server}'"
            printf "  │  %-77s│\n" "   → '${new_server}')"
            echo "  └─────────────────────────────────────────────────────────────────────────────┘"
          fi

          local ans
          read -r -p "  Apply this patch? [y/N/a(ll remaining)/q(uit)]: " ans
          if [[ "$ans" =~ ^[Qq]$ ]]; then
            info "Quitting patch loop."
            return 0
          elif [[ "$ans" =~ ^[Aa]$ ]]; then
            local k
            for k in $(seq "$j" "$((${#p_display[@]}-1))"); do
              _patch_argocd_resource "${p_kind[$k]}" "${p_app_name[$k]}" "${p_app_ns[$k]}" "$old_server" "$new_server" \
                && patched=$((patched+1)) || failed=$((failed+1))
            done
            break
          elif [[ "$ans" =~ ^[Yy]$ ]]; then
            _patch_argocd_resource "$pkind" "$pname" "$pns" "$old_server" "$new_server" \
              && patched=$((patched+1)) || failed=$((failed+1))
          else
            info "  Skipped ${p_display[$j]}."
            skipped=$((skipped+1))
          fi
        done
        ok "Patch round complete: ${patched} patched, ${skipped} skipped, ${failed} failed."
      fi
    fi

    # --- 6. Loop prompt ---
    [[ ${#all_gitops_ns[@]} -le 1 ]] && break
    echo ""
    read -r -p "Patch another gitops namespace? [y/N/q]: " again
    [[ "$again" =~ ^[Yy]$ ]] || break
  done
  ok "ArgoCD destination patching done."
}

# Apply a single ArgoCD Application or AppProject server URL patch
_patch_argocd_resource() {
  local kind="$1" name="$2" ns="$3" old_server="$4" new_server="$5"
  if [[ "$kind" == "application" ]]; then
    if oc patch application.argoproj.io "$name" -n "$ns" \
        --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/destination/server\",\"value\":\"${new_server}\"}]" \
        >>"$LOG_FILE" 2>&1; then
      ok "  Patched Application '${name}' (${ns})"
      local after_server
      after_server=$(oc get application.argoproj.io "$name" -n "$ns" \
        -o jsonpath='{.spec.destination.server}' 2>/dev/null || echo "(unknown)")
      echo "  ┌─── AFTER ───────────────────────────────────────────────────────────────────┐"
      printf "  │  %-77s│\n" "spec.destination.server: ${after_server}"
      echo "  └─────────────────────────────────────────────────────────────────────────────┘"
      return 0
    else
      warn "  Failed to patch Application '${name}' (${ns})"
      return 1
    fi
  else
    local new_dests
    new_dests=$(oc get appproject.argoproj.io "$name" -n "$ns" -o json 2>/dev/null | \
      python3 -c "
import json,sys
d=json.load(sys.stdin)
dests=d.get('spec',{}).get('destinations',[])
for dest in dests:
    if dest.get('server','')=='${old_server}':
        dest['server']='${new_server}'
print(json.dumps(dests))
" 2>/dev/null)
    if [[ -n "$new_dests" ]] && oc patch appproject.argoproj.io "$name" -n "$ns" \
        --type=merge \
        -p="{\"spec\":{\"destinations\":${new_dests}}}" \
        >>"$LOG_FILE" 2>&1; then
      ok "  Patched AppProject '${name}' (${ns})"
      local after_dests
      after_dests=$(oc get appproject.argoproj.io "$name" -n "$ns" -o json 2>/dev/null | \
        python3 -c "
import json,sys
d=json.load(sys.stdin)
for dest in d.get('spec',{}).get('destinations',[]):
    print('  server=%-55s namespace=%s' % (dest.get('server',''),dest.get('namespace','')))
" 2>/dev/null || echo "  (unknown)")
      echo "  ┌─── AFTER ───────────────────────────────────────────────────────────────────┐"
      while IFS= read -r line; do
        printf "  │  %-77s│\n" "$line"
      done <<< "$after_dests"
      echo "  └─────────────────────────────────────────────────────────────────────────────┘"
      return 0
    else
      warn "  Failed to patch AppProject '${name}' (${ns})"
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Post-restore: report ArgoCD Application sync / health status
# ---------------------------------------------------------------------------
check_argocd_apps() {
  info "--- ArgoCD Application sync / health check ---"
  local found=false gitops_ns

  for gitops_ns in ose-gitops ose-gitops-bd; do
    oc get ns "$gitops_ns" >/dev/null 2>&1 || continue
    local apps_json
    apps_json=$(oc get application.argoproj.io -n "$gitops_ns" -o json 2>/dev/null) || continue
    found=true

    info "ArgoCD apps in '${gitops_ns}':"
    echo "$apps_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=[]
for item in d.get("items",[]):
    name=item["metadata"]["name"]
    status=item.get("status",{})
    sync=status.get("sync",{}).get("status","Unknown")
    health=status.get("health",{}).get("status","Unknown")
    flag=" ⚠" if not (sync=="Synced" and health=="Healthy") else ""
    rows.append((name,sync,health,flag))
rows.sort()
print(f"  {\"NAME\":<50} {\"SYNC\":<15} {\"HEALTH\"}")
print(f"  {\"-\"*50} {\"-\"*15} {\"-\"*10}")
for name,sync,health,flag in rows:
    print(f"  {name:<50} {sync:<15} {health}{flag}")
' 2>/dev/null | tee -a "$LOG_FILE"
    echo ""
  done

  $found || warn "No ArgoCD Application CRs found in ose-gitops / ose-gitops-bd (may still be syncing)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  clear
  # Compact block-letter banner
  local G='\033[1;32m' A='\033[0;32m' DIM='\033[2;32m' R='\033[0m' BLD='\033[1m'
  printf "${G}"
  cat <<'LED'

 
  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

  ██████╗   ██████╗    ███████╗  ███╗   ██╗  ███████╗  ██╗  ██╗  ██╗  ███████╗  ████████╗
  ██╔══██╗  ██╔══██╗   ██╔════╝  ████╗  ██║  ██╔════╝  ██║  ██║  ██║  ██╔════╝  ╚══██╔══╝
  ██║  ██║  ██████╔╝   █████╗    ██╔██╗ ██║  ███████╗  ███████║  ██║  █████╗       ██║   
  ██║  ██║  ██╔═══╝    ██╔══╝    ██║╚██╗██║  ╚════██║  ██╔══██║  ██║  ██╔══╝       ██║   
  ╚██████╔╝  ██║        ███████╗  ██║ ╚████║  ███████║  ██║  ██║  ██║  ██║          ██║   
   ╚═════╝   ╚═╝        ╚══════╝  ╚═╝  ╚═══╝  ╚══════╝  ╚═╝  ╚═╝  ╚═╝  ╚═╝          ╚═╝   

  ██████╗   ██╗  ███████╗   █████╗   ███████╗  ████████╗  ███████╗  ██████╗ 
  ██╔══██╗  ██║  ██╔════╝  ██╔══██╗  ██╔════╝  ╚══██╔══╝  ██╔════╝  ██╔══██╗
  ██║  ██║  ██║  ███████╗  ███████║  ███████╗     ██║     █████╗    ██████╔╝
  ██║  ██║  ██║  ╚════██║  ██╔══██║  ╚════██║     ██║     ██╔══╝    ██╔══██╗
  ██████╔╝  ██║  ███████║  ██║  ██║  ███████║     ██║     ███████╗  ██║  ██║
  ╚═════╝   ╚═╝  ╚══════╝  ╚═╝  ╚═╝  ╚══════╝     ╚═╝     ╚══════╝  ╚═╝  ╚═╝

  ██████╗   ███████╗  ██████╗   ██████╗   ██╗   ██╗  ███████╗  ██████╗   ██╗   ██╗
  ██╔══██╗  ██╔════╝  ██╔════╝  ██╔══██╗  ██║   ██║  ██╔════╝  ██╔══██╗  ╚██╗ ██╔╝
  ██████╔╝  █████╗    ██║       ██║  ██║  ██║   ██║  █████╗    ██████╔╝   ╚████╔╝ 
  ██╔══██╗  ██╔══╝    ██║       ██║  ██║  ╚██╗ ██╔╝  ██╔══╝    ██╔══██╗    ╚██╔╝  
  ██║  ██║  ███████╗  ╚██████╗  ╚██████╔╝   ╚████╔╝   ███████╗  ██║  ██║     ██║   
  ╚═╝  ╚═╝  ╚══════╝   ╚═════╝   ╚═════╝     ╚═══╝    ╚══════╝  ╚═╝  ╚═╝     ╚═╝

  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░


LED
  printf "${R}"
  printf "${A}  %s${R}\n" "OpenShift Disaster Recovery  ·  Velero / OADP  ·  oc-dr.sh"
  printf "${DIM}  %s${R}\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local Y='\033[1;33m'
  printf "${Y}"
  cat <<'CHALLENGES'
  ╔════════════════════════════════════════════════════════════════════════════════════════════════╗
  ║                    ⚠  BACKUP / RECOVERY CHALLENGES TO CONSIDER  ⚠                              ║
  ╠════════════════════════════════════════════════════════════════════════════════════════════════╣
  ║                                                                                                ║
  ║  Running stateful workloads on OpenShift requires special attention to backup and              ║
  ║   restore disciplines — especially when Persistent Volumes hold data that must not be lost.    ║
  ║                                                                                                ║ 
  ║  While backups protect against misconfiguration, data loss, bugs and human error               ║
  ║    there are key challenges to address:                                                        ║
  ║                                                                                                ║
  ║  ▸ Full DR exercises are done too infrequently — or never.                                     ║
  ║  ▸ Does backup/restore tooling work consistently across ALL clusters?                          ║
  ║    (Currently using Velero / Restic)                                                           ║
  ║  ▸ Are the scheduled backup jobs actually running and completing?                              ║
  ║  ▸ Large PVCs can take a long time to backup and restore (if not using snapshots).             ║
  ║  ▸ Do we know HOW to restore — or are we expecting JNData to do it for us?                     ║
  ║    (Are StorageClasses tagged backup=yes actually usable on the DR cluster?)                   ║
  ║  ▸ One backup setup does not fit all cluster needs.                                            ║
  ║  ▸ Do we need continuous transaction log backups to restore to current state?                  ║
  ║  ▸ Can the application/business tolerate a point-in-time restore without                       ║
  ║    subsequent log-apply to catch up to the moment of failure?                                  ║
  ║                                                                                                ║
  ╚════════════════════════════════════════════════════════════════════════════════════════════════╝
CHALLENGES
  printf "${R}"
  echo ""

  _play_dr_animation
  echo ""

  cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════════════╗
  ║         oc-dr.sh — OpenShift Disaster Recovery via Velero            ║
  ╠══════════════════════════════════════════════════════════════════════╣
  ║  Flow:                                                               ║
  ║   1. Check prerequisites (oc login, OADP CRDs, BSL, Velero pod)      ║
  ║   2. Prereq restores:                                                ║
  ║      a. Namespaces / NetworkPolicies / EgressFirewalls               ║
  ║      b. DB2 StatefulSets + PVCs (if db2u-velero-backup* found)       ║
  ║      c. MEP 2-phase: SA/ClusterRole → PVCs (if dxo-p* found)         ║
  ║      d. WCM 2-phase: SA/ClusterRole → PVCs (if dxo-p* found)         ║
  ║      e. EBA 2-phase: SA/ClusterRole → PVCs (if dxo-p* found)         ║
  ║      f. Sealed Secrets                                               ║
  ║      g. ArgoCD AppProjects / Applications (ose-gitops + bd)          ║
  ║      h. Optional: patch ArgoCD destinations for disaster cluster     ║
  ║   3. Select backup(s) — newest shown per base name                   ║
  ║   4. Select namespaces to restore per backup                         ║
  ║   5. Review restore YAMLs, then confirm to apply or save only        ║
  ║   6. Poll for completion with live status, validate pods/PVCs/routes ║
  ║   7. Optionally restore another backup (interactive loop)            ║
  ║   8. ArgoCD Application sync / health summary                        ║
  ╚══════════════════════════════════════════════════════════════════════╝

BANNER
  printf "${R}"
  echo ""
  read -r -p "  Press Enter to continue..." _pause_input
  echo ""


  info "=== OpenShift Velero DR run started (log: ${LOG_FILE}) ==="

  check_prereqs

  if $LIST_ONLY; then
    list_backups
    exit 0
  fi

  run_prereq_restores

  local NAMESPACES_FIXED="$NAMESPACES"   # value from -n flag (applies to all iterations)
  local DRY_RUN_FLAG=$DRY_RUN            # original --dry-run flag; reset each iteration
  local BACKUP_NAMES_FLAG=()
  [[ ${#BACKUP_NAMES[@]} -gt 0 ]] && BACKUP_NAMES_FLAG=("${BACKUP_NAMES[@]}")

  # Accumulate results across all loop iterations for final summary
  declare -a ALL_SUMMARY_KEYS=()
  declare -a ALL_SUMMARY_RESULTS=()
  local overall_ok=true

  while true; do
    # Reset per-iteration state
    BACKUP_NAMES=()
    [[ ${#BACKUP_NAMES_FLAG[@]} -gt 0 ]] && BACKUP_NAMES=("${BACKUP_NAMES_FLAG[@]}")
    DRY_RUN=$DRY_RUN_FLAG
    INCLUDE_RESOURCES=""

    # 1. Select backups
    if [[ ${#BACKUP_NAMES[@]} -eq 0 ]]; then
      select_backup_interactive
    fi

    # 2. Validate each backup and collect per-backup namespace selections
    declare -a PER_BACKUP_NS=()
    NS_MAPPING_ORIG=()
    NS_MAPPING_TARGET=()
    local b_idx
    for b_idx in "${!BACKUP_NAMES[@]}"; do
      BACKUP_NAME="${BACKUP_NAMES[$b_idx]}"
      validate_backup

      # Describe backup and optionally filter resource types
      select_included_resources_interactive "$BACKUP_NAME"

      if [[ -n "$NAMESPACES_FIXED" ]]; then
        PER_BACKUP_NS[$b_idx]="$NAMESPACES_FIXED"
      elif $RESTORE_ALL_NAMESPACES; then
        local all_ns
        all_ns=$(get_backup_included_namespaces)
        [[ -n "$all_ns" ]] || die "Backup '${BACKUP_NAME}' targets '*' or namespace list could not be parsed; use -n to specify namespaces explicitly."
        PER_BACKUP_NS[$b_idx]="$all_ns"
      else
        NAMESPACES=""
        select_namespaces_interactive
        PER_BACKUP_NS[$b_idx]="$NAMESPACES"
      fi
      info "Backup '${BACKUP_NAME}' → namespaces: ${PER_BACKUP_NS[$b_idx]}"

      # Prompt namespace mapping per namespace right after selection
      if ! $NON_INTERACTIVE; then
        prompt_namespace_mapping "${PER_BACKUP_NS[$b_idx]}"
      fi
    done

    # 3. Show plan, render + preview all restore YAMLs, then confirm
    if [[ -t 0 ]] && ! $NON_INTERACTIVE; then
      echo "" | tee -a "$LOG_FILE"
      info "Recovery plan:"
      for b_idx in "${!BACKUP_NAMES[@]}"; do
        info "  Backup '${BACKUP_NAMES[$b_idx]}' → ${PER_BACKUP_NS[$b_idx]}"
      done

      echo ""
      info "Restore YAMLs that will be applied:"
      local prev_b_idx prev_ns prev_rname prev_yaml
      for prev_b_idx in "${!BACKUP_NAMES[@]}"; do
        BACKUP_NAME="${BACKUP_NAMES[$prev_b_idx]}"
        IFS=',' read -ra _prev_ns_arr <<< "${PER_BACKUP_NS[$prev_b_idx]}"
        for prev_ns in "${_prev_ns_arr[@]}"; do
          prev_rname="${RESTORE_NAME_PREFIX}-${prev_ns}-${TIMESTAMP}"
          prev_yaml="${YAML_DIR}/preview-${prev_b_idx}-${prev_ns}.yaml"
          render_restore_yaml "$prev_ns" "$prev_rname" "$prev_yaml" "$(get_ns_mapping "$prev_ns")"
          echo ""
          info "  → ${prev_rname}"
          echo "  ┌─────────────────────────────────────────────────────────────────────────────────┐"
          while IFS= read -r line; do
            printf "  │  %-81s│\n" "$line"
          done < "$prev_yaml"
          echo "  └─────────────────────────────────────────────────────────────────────────────────┘"
        done
      done
      echo ""
      read -r -p "Run recovery now? [y/N]: " proceed
      if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        info "Recovery not confirmed — rendering restore YAML only (no changes applied)."
        DRY_RUN=true
      fi
    fi

    # 4. Execute restores across all selected backups
    declare -a RESTORE_NAMES_ARR=()
    local s_start=${#ALL_SUMMARY_KEYS[@]}
    local s_idx=$s_start

    for b_idx in "${!BACKUP_NAMES[@]}"; do
      BACKUP_NAME="${BACKUP_NAMES[$b_idx]}"
      IFS=',' read -ra NS_ARRAY <<< "${PER_BACKUP_NS[$b_idx]}"

      RESTORE_NAMES_ARR=()
      local i
      for i in "${!NS_ARRAY[@]}"; do
        pre_restore_check "${NS_ARRAY[$i]}"
        RESTORE_NAMES_ARR[$i]=$(create_restore "${NS_ARRAY[$i]}")
      done

      for i in "${!NS_ARRAY[@]}"; do
        local ns="${NS_ARRAY[$i]}"
        local rname="${RESTORE_NAMES_ARR[$i]:-}"
        local result
        if [[ -z "$rname" ]]; then
          result="CREATE_FAILED"
        elif wait_for_restore "$rname"; then
          result="RESTORE_OK"
          local _mapped; _mapped="$(get_ns_mapping "$ns")"
          validate_namespace "${_mapped:-$ns}"
        else
          result="RESTORE_FAILED_OR_PARTIAL"
        fi
        ALL_SUMMARY_KEYS[$s_idx]="${BACKUP_NAME}/${ns}"
        ALL_SUMMARY_RESULTS[$s_idx]="$result"
        [[ "$result" != "RESTORE_OK" ]] && overall_ok=false
        s_idx=$((s_idx + 1))
      done
    done

    if $DRY_RUN; then
      info "Restore manifests saved under: ${YAML_DIR}"
    else
      info "Round complete."
    fi

    # 5. Ask to continue (interactive mode only; skip if -b was given)
    if [[ -t 0 ]] && ! $NON_INTERACTIVE && [[ ${#BACKUP_NAMES_FLAG[@]} -eq 0 ]]; then
      echo ""
      read -r -p "Restore another backup? [y/N]: " again
      [[ "$again" =~ ^[Yy]$ ]] || break
    else
      break
    fi
  done

  # Final summary
  {
    echo "=========================================="
    echo " DR Run Summary - ${TIMESTAMP}"
    echo "=========================================="
    for i in "${!ALL_SUMMARY_KEYS[@]}"; do
      printf "  %-50s %s\n" "${ALL_SUMMARY_KEYS[$i]}" "${ALL_SUMMARY_RESULTS[$i]:-UNKNOWN}"
    done
    echo "=========================================="
    echo " Restore manifests saved under: ${YAML_DIR}"
  } | tee "$SUMMARY_FILE" | tee -a "$LOG_FILE"

  info "Full log: ${LOG_FILE}"
  info "Summary:  ${SUMMARY_FILE}"

  check_argocd_apps

  $overall_ok || exit 1
  exit 0
}

main "$@"


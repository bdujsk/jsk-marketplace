---
name: ocm-rosa-info
description: Reports on ROSA/OpenShift clusters (vCPUs, subscriptions, capacity/usage, upgrade status, machine/node pools, and CVE/vulnerability findings) via the OCM CLI and console.redhat.com APIs. Use when the user asks about ROSA cluster inventory, vCPU/core usage, subscription capacity, available OpenShift upgrades, scheduled updates, machine pool status, or CVEs/vulnerabilities affecting their ROSA clusters.
---

# ROSA vCPU & Cluster Status Report


Runs `ocm-rosa-info.sh`, a bash script that pulls live data from the OCM
CLI and console.redhat.com APIs and prints a full text report covering:

1. **Total vCPUs by group** - clusters grouped by `<prefix>-u<N>` naming pattern.
2. **OpenShift Subscriptions** - all subscriptions on the account (incl. deprovisioned).
3. **Subscription Capacity & Usage** - contracted capacity vs. latest usage
   (same data as `console.redhat.com/subscriptions/usage/openshift`).
4. **Usage Trend** - text-based bar chart of daily core-hour usage, last 30 days.
5. **Usage by Billing Category vs Threshold** - cumulative "monthly pre-paid"
   and "monthly on-demand" usage plotted against the pre-paid subscription
   threshold, with an overage note if the prepaid pool has been exceeded.
6. **Upgrade Status (per cluster)** - for each cluster: available upgrade
   versions, machine/node pools (with labels, taints, and whether a pool is
   currently being updated), and any scheduled update.
7. **Critical/High Vulnerabilities (Insights Advisor)** - Advisor findings
   with `total_risk >= 3` (High/Critical), per cluster.
8. **Critical / Important CVEs (OpenShift Vulnerability Service)** - real
   per-cluster package/image CVE scan results, filtered to CVSS3 score > 8,
   each with a "how to fix" block (Red Hat advisory link, affected
   image/version, and a Red Hat PSIRT "is OCP 4 actually affected" check to
   flag likely false positives).

## Prerequisites

- **`ocm` CLI installed and logged in.** This is required before running the
  script - it is the source of the bearer token used for every API call
  (both the OCM `clusters_mgmt`/`accounts_mgmt` APIs and the
  console.redhat.com APIs, which accept the same SSO token).

  ```bash
  ocm login --token=<offline-token>
  ```

  Get an offline token from https://console.redhat.com/openshift/token.
  Verify you're logged in with:

  ```bash
  ocm whoami
  ```

  The script checks this itself and exits with an error message if you are
  not logged in.

- **`jq`** - used throughout for JSON parsing/filtering.
- **`curl`** - used for direct console.redhat.com API calls (rhsm-subscriptions,
  insights-results-aggregator, ocp-vulnerability, and the public Red Hat
  securitydata API).
- **`column`** and **`awk`** - standard on macOS/Linux, used for table formatting.


## Instructions for Running the script

Run `ocm whoami` first.
If not logged in, tell the user to run`ocm login --token=...` themselves.
Never ask for or print the token.

Run `scripts/ocm-rosa-info.sh > /tmp/rosa-report.txt` (stderr = progress).
Read the report in sections; don't paste it in full.
Lead with a short summary: total vCPUs, overage vs. prepaid threshold, clusters with pending upgrades, and CVEs with CVSS > 8.

For CVEs, say which look like PSIRT false positives, and point to the Advisory link before recommending any action.

The script is read-only.
Do not run upgrades or modify clusters.


```bash
./ocm-rosa-info.sh
```

No arguments are needed. It auto-discovers all clusters visible to the
logged-in OCM account/org. Run it from a shell with network access to
`console.redhat.com` and `access.redhat.com`.

Progress/status messages go to stderr; the report itself is on stdout, so
you can redirect just the report if needed:

```bash
./ocm-rosa-info.sh > report.txt
```

## Notes / known limitations

- Capacity/usage figures approximate the console UI's own billing-period
  calculation; they won't match it exactly (see in-script comments).
- The Insights Advisor section may legitimately show "None found" for all
  clusters - this reflects real Advisor data (a narrower, curated
  best-practice/config rule set), not a script defect.
- The "Critical/Important CVEs" PSIRT check flags likely false positives
  (package present in an image but Red Hat has determined the product isn't
  exploitable), but always double check the linked advisory before acting.
- All 9 example clusters this script was developed against are Hosted
  Control Plane (HCP) clusters; the script also supports classic clusters
  (it branches on `hypershift.enabled` for pools/upgrade-policy endpoints).

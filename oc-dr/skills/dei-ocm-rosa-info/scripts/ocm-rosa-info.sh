#!/usr/bin/env bash
# ocm-rosa-info.sh
#
# Prints a table of ROSA/OpenShift clusters (from console.redhat.com / OCM)
# with their total vCPU count, grouped by the "<prefix>-u<N>" naming pattern
# (e.g. "management-u1", "microservices-u1"). Also lists all OpenShift
# subscriptions registered on the account (including deprovisioned ones),
# and shows subscription capacity/usage data (rhsm-subscriptions API) similar
# to the "Remaining capacity" widget on console.redhat.com/subscriptions/usage/openshift.
#
# Usage:
#   ./ocm-rosa-info.sh
#
# Requires: ocm CLI logged in (ocm login --token=<offline-token>), jq, curl

set -euo pipefail

command -v ocm >/dev/null 2>&1 || { echo "ocm CLI not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

# Renders a TSV (header + rows) as an aligned table indented by 4 spaces.
print_table() {
  column -t -s $'\t' | sed 's/^/    /'
}

ocm whoami >/dev/null 2>&1 || { echo "Not logged in. Run: ocm login --token=<offline-token>" >&2; exit 1; }

echo "Fetching clusters ..." >&2

clusters_json=$(ocm get /api/clusters_mgmt/v1/clusters)

cluster_count=$(echo "$clusters_json" | jq '.items | length')
if [ "$cluster_count" -eq 0 ]; then
  echo "No clusters found" >&2
  exit 0
fi

echo "Fetching per-cluster vCPU metrics via subscriptions ..." >&2

# For each cluster, fetch its subscription (which carries the live metrics: cpu.total, nodes.total)
merged_json=$(echo "$clusters_json" | jq -c '.items[] | {id, external_id, name: .display_name, state, version: .openshift_version, available_upgrades: (.version.available_upgrades // []), hypershift_enabled: (.hypershift.enabled // false), sub_id: .subscription.id}' | \
while IFS= read -r row; do
  sub_id=$(echo "$row" | jq -r '.sub_id')
  sub_json=$(ocm get "/api/accounts_mgmt/v1/subscriptions/$sub_id" 2>/dev/null || echo '{}')
  cpu_total=$(echo "$sub_json" | jq '(.metrics[0].cpu.total.value // 0)')
  nodes_total=$(echo "$sub_json" | jq '(.metrics[0].nodes.total // 0)')
  echo "$row" | jq -c --argjson cpu "$cpu_total" --argjson nodes "$nodes_total" '. + {VCpus: $cpu, Nodes: $nodes}'
done | jq -s '.')

# Derive a Group from the cluster name: the trailing "<app>-<env><N>" portion
# (e.g. "management-u1", "documentserv-p1", "sasaml-i1"), regardless of any
# leading prefix (e.g. "bd-ose-"). Falls back to the full name when that
# pattern isn't present.
merged_json=$(echo "$merged_json" | jq '
  map(. + {
    Group: (
      (.name // "" | capture("(?<g>[a-zA-Z0-9]+-[a-zA-Z][0-9]+)$").g?)
      // (.name // "ungrouped")
    )
  })
')

echo "$merged_json" | jq -r '
  (["CLUSTER_ID","NAME","STATE","VERSION","NODES","VCPUS","GROUP"] | @tsv),
  (.[] | [.id, .name, .state, .version, (.Nodes|tostring), (.VCpus|tostring), .Group] | @tsv)
' | column -t -s $'\t'

echo
echo "=== Total vCPUs by Group ==="
echo "$merged_json" | jq -r '
  group_by(.Group)
  | map({Group: .[0].Group, Clusters: length, TotalVCpus: (map(.VCpus) | add)})
  | sort_by(.Group)
  | (["GROUP","CLUSTERS","TOTAL_VCPUS"] | @tsv),
  (.[] | [.Group, (.Clusters|tostring), (.TotalVCpus|tostring)] | @tsv)
' | column -t -s $'\t'

echo
total_vcpus=$(echo "$merged_json" | jq '[.[].VCpus] | add')
total_clusters=$(echo "$merged_json" | jq 'length')
echo "TOTAL: $total_clusters clusters, $total_vcpus vCPUs"

echo
echo "=== OpenShift Subscriptions (console.redhat.com) ===" >&2
subscriptions_json=$(ocm get /api/accounts_mgmt/v1/subscriptions)
echo "$subscriptions_json" | jq -r '
  (["NAME","STATUS","BILLING_MODEL","PLAN","CLOUD_PROVIDER"] | @tsv),
  (.items[] | [.display_name, .status, .cluster_billing_model, .plan.id, .cloud_provider_id] | @tsv)
' | column -t -s $'\t'

echo
echo "=== Subscription Capacity & Usage (console.redhat.com/subscriptions/usage/openshift) ===" >&2
# Same data backing the "Remaining capacity" widget on the Usage page.
# Uses the rhsm-subscriptions API via the ocm SSO bearer token.
#
# What "Remaining capacity" means:
#   Remaining capacity = Total contracted capacity - Cumulative usage consumed
#   so far in the current subscription/billing term.
#
#   - Total capacity  = the total core-hours your organization has committed
#     to / purchased for this subscription term (e.g. a Red Hat Marketplace/AWS
#     commitment running until the subscription's "next_event_date").
#   - Usage           = core-hours actually consumed by running clusters,
#     accumulated hour-by-hour since the term started (concurrent cores x
#     hours running, summed across all clusters under that subscription).
#   - Remaining       = what's left of that pool before usage exceeds the
#     contracted commitment. It's a CUMULATIVE running total over the whole
#     term, not a daily/instant number - going over it typically means
#     overage/true-up billing rather than clusters being shut off.
#
# NOTE: the calculation below only approximates this using a single day's
# usage (not the full cumulative term-to-date total), so it will NOT exactly
# match the console page's own "Remaining capacity" figure.
RHSM_TOKEN=$(ocm token)
RHSM_PRODUCT="rosa"
RHSM_METRIC="Cores"

capacity_json=$(curl -s -H "Authorization: Bearer $RHSM_TOKEN" \
  "https://console.redhat.com/api/rhsm-subscriptions/v1/subscriptions/products/$RHSM_PRODUCT")

total_capacity=$(echo "$capacity_json" | jq '[.data[].total_capacity] | add // 0')

usage_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
usage_begin=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "1 day ago" +%Y-%m-%dT%H:%M:%SZ)

usage_json=$(curl -s -H "Authorization: Bearer $RHSM_TOKEN" --get \
  "https://console.redhat.com/api/rhsm-subscriptions/v1/tally/products/$RHSM_PRODUCT/$RHSM_METRIC" \
  --data-urlencode "granularity=DAILY" \
  --data-urlencode "beginning=$usage_begin" \
  --data-urlencode "ending=$usage_end")

latest_usage=$(echo "$usage_json" | jq '[.data[] | select(.has_data == true) | .value] | last // 0')

echo "$capacity_json" | jq -r --argjson metric_id "\"$RHSM_METRIC\"" '
  (["SKU","PRODUCT_NAME","BILLING_PROVIDER","METRIC","TOTAL_CAPACITY"] | @tsv),
  (.data[] | [.sku, .product_name, .billing_provider, (.metric_id // $metric_id), (.total_capacity|tostring)] | @tsv)
' | column -t -s $'\t'

echo
echo "Product: $RHSM_PRODUCT | Metric: $RHSM_METRIC (core-hours)"
echo "Total capacity      : $total_capacity"
echo "Latest usage (1 day): $latest_usage"
echo "Note: 'Remaining capacity' on the console page is computed over its own"
echo "      billing-period window; this is a same-day approximation"
echo "      (total_capacity - latest_usage), not the exact UI figure."

echo
echo "=== Usage Trend (last 30 days, $RHSM_METRIC core-hours) ===" >&2
# Text-based version of the usage graph on console.redhat.com/subscriptions/usage/openshift.
# (The API's MONTHLY granularity returns no data for this account/metric, so
# this renders a daily bar chart over the last 30 days instead - same data
# source, just a finer-grained x-axis.)
trend_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
trend_begin=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%SZ)

trend_json=$(curl -s -H "Authorization: Bearer $RHSM_TOKEN" --get \
  "https://console.redhat.com/api/rhsm-subscriptions/v1/tally/products/$RHSM_PRODUCT/$RHSM_METRIC" \
  --data-urlencode "granularity=DAILY" \
  --data-urlencode "beginning=$trend_begin" \
  --data-urlencode "ending=$trend_end" || echo '{}')

trend_max=$(echo "$trend_json" | jq '[.data[].value] | max // 0')
if [ "$trend_max" -eq 0 ]; then
  echo "    No usage data available for this period."
else
  BAR_WIDTH=50
  echo "$trend_json" | jq -r --argjson max "$trend_max" --argjson width "$BAR_WIDTH" '
    .data[] | [(.date | split("T")[0]), (.value|tostring), (((.value / $max) * $width) | floor | tostring)] | @tsv
  ' | while IFS=$'\t' read -r d v barlen; do
      bar=$(printf '%*s' "$barlen" '' | tr ' ' '#')
      printf "    %-12s %8s  %s\n" "$d" "$v" "$bar"
    done
  echo
  awk -v max="$trend_max" -v width="$BAR_WIDTH" 'BEGIN { printf "    Scale: each # ~ %.1f core-hours. Peak day: %d\n", max/width, max }'
fi

print_billing_vs_threshold() {
  local label="$1" period_begin="$2" period_end="$3"

  echo
  echo "=== Usage by Billing Category vs Threshold ($label) ===" >&2
  echo
  echo "=== Usage by Billing Category vs Threshold ($label) ==="

  local prepaid_json ondemand_json threshold_json threshold_val
  prepaid_json=$(curl -s -H "Authorization: Bearer $RHSM_TOKEN" --get   "https://console.redhat.com/api/rhsm-subscriptions/v1/tally/products/$RHSM_PRODUCT/$RHSM_METRIC"   --data-urlencode "granularity=DAILY"   --data-urlencode "beginning=$period_begin"   --data-urlencode "ending=$period_end"   --data-urlencode "billing_category=prepaid"   --data-urlencode "use_running_totals_format=true" || echo '{}')

  ondemand_json=$(curl -s -H "Authorization: Bearer $RHSM_TOKEN" --get   "https://console.redhat.com/api/rhsm-subscriptions/v1/tally/products/$RHSM_PRODUCT/$RHSM_METRIC"   --data-urlencode "granularity=DAILY"   --data-urlencode "beginning=$period_begin"   --data-urlencode "ending=$period_end"   --data-urlencode "billing_category=on-demand"   --data-urlencode "use_running_totals_format=true" || echo '{}')

  threshold_json=$(curl -s -H "Authorization: Bearer $RHSM_TOKEN" --get   "https://console.redhat.com/api/rhsm-subscriptions/v1/capacity/products/$RHSM_PRODUCT/$RHSM_METRIC"   --data-urlencode "granularity=DAILY"   --data-urlencode "beginning=$period_begin"   --data-urlencode "ending=$period_end" || echo '{}')

  threshold_val=$(echo "$threshold_json" | jq '[.data[].value] | max // 0')

  if [ "$threshold_val" -eq 0 ] || [ "$(echo "$prepaid_json" | jq '.data | length // 0')" -eq 0 ]; then
    echo "    No threshold/capacity data available for this period."
    return
  fi

  local bar_width=40
  jq -n --argjson prepaid "$prepaid_json" --argjson ondemand "$ondemand_json" --argjson max "$threshold_val" --argjson width "$bar_width" -r '
    (["DATE","PREPAID_CUML","ON_DEMAND_CUML","PCT_OF_THRESHOLD"] | @tsv),
    (range(0; ($prepaid.data | length)) as $i |
      [$prepaid.data[$i], $ondemand.data[$i]] as [$p, $o] |
      [
        ($p.date | split("T")[0]),
        ($p.value|tostring),
        ($o.value|tostring),
        (((($p.value + $o.value) / $max) * 100 | floor | tostring) + "%")
      ] | @tsv)
  ' | print_table

  echo
  echo "    Pre-paid subscription threshold: $threshold_val core-hours"
  echo
  echo "    Cumulative usage vs threshold (last day of period):"
  jq -n --argjson prepaid "$prepaid_json" --argjson ondemand "$ondemand_json" --argjson max "$threshold_val" --argjson width "$bar_width" -r '
    ($prepaid.data[-1].value) as $p |
    ($ondemand.data[-1].value) as $o |
    ((($p + $o) / $max) * $width) as $ratio |
    ([($ratio | floor), $width] | min) as $barlen |
    "\($barlen)\t\(if $ratio > $width then "OVER" else "OK" end)"
  ' | while IFS=$'\t' read -r barlen overflag; do
      bar=$(printf '%*s' "$barlen" '' | tr ' ' '#')
      rest=$((bar_width - barlen))
      [ "$rest" -lt 0 ] && rest=0
      pad=$(printf '%*s' "$rest" '' | tr ' ' '.')
      echo "    [${bar}${pad}] (threshold = right edge)"
      if [ "$overflag" = "OVER" ]; then
        echo "    NOTE: usage has exceeded the pre-paid threshold - the excess is now being billed as on-demand overage."
      fi
    done
}

cur_month_start=$(date -u +%Y-%m-01T00:00:00Z)
cur_month_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prev_month_start=$(date -u -v-1m +%Y-%m-01T00:00:00Z 2>/dev/null || date -u -d "$(date -u +%Y-%m-01) -1 month" +%Y-%m-01T00:00:00Z)
prev_month_end="$cur_month_start"
prev_month_label=$(LC_TIME=C date -u -j -f %Y-%m-%dT%H:%M:%SZ "$prev_month_start" +"%B %Y" 2>/dev/null || LC_TIME=C date -u -d "$prev_month_start" +"%B %Y")
cur_month_label=$(LC_TIME=C date -u -j -f %Y-%m-%dT%H:%M:%SZ "$cur_month_start" +"%B %Y" 2>/dev/null || LC_TIME=C date -u -d "$cur_month_start" +"%B %Y")

print_billing_vs_threshold "Previous Month: $prev_month_label" "$prev_month_start" "$prev_month_end"
print_billing_vs_threshold "Current Month: $cur_month_label" "$cur_month_start" "$cur_month_end"

echo
echo "=== Upgrade Status (per cluster) ==="
# Each cluster's current version carries its own "available_upgrades" list
# (from clusters_mgmt), i.e. only the versions it is actually eligible to
# upgrade to - not the full catalog of OpenShift versions. We also show each
# cluster's machine pools (classic) / node pools (hosted-CP) and their
# current versions (since pools can lag behind the control plane version),
# plus any scheduled upgrade (control_plane/upgrade_policies for hosted-CP,
# upgrade_policies for classic clusters).

while IFS=$'\t' read -r cluster_id name current_version upgrades hypershift_enabled; do
  echo
  printf '%s\n' "----------------------------------------"
  printf 'Cluster: %s  (current version: %s)\n' "$name" "$current_version"
  printf '%s\n' "----------------------------------------"

  echo "  Available Upgrades:"
  if [ -z "$upgrades" ]; then
    echo "    None available."
  else
    { printf 'TARGET_VERSION\n'; echo "$upgrades" | tr ',' '\n'; } | print_table
  fi

  if [ "$hypershift_enabled" = "true" ]; then
    pools_json=$(ocm get "/api/clusters_mgmt/v1/clusters/$cluster_id/node_pools" 2>/dev/null || echo '{}')
    policies_json=$(ocm get "/api/clusters_mgmt/v1/clusters/$cluster_id/control_plane/upgrade_policies" 2>/dev/null || echo '{}')
  else
    pools_json=$(ocm get "/api/clusters_mgmt/v1/clusters/$cluster_id/machine_pools" 2>/dev/null || echo '{}')
    policies_json=$(ocm get "/api/clusters_mgmt/v1/clusters/$cluster_id/upgrade_policies" 2>/dev/null || echo '{}')
  fi

  echo
  echo "  Machine/Node Pools:"
  pool_count=$(echo "$pools_json" | jq '.items // [] | length')
  if [ "$pool_count" -eq 0 ]; then
    echo "    None found."
  else
    # For hosted-CP clusters, each node pool can have its own upgrade policy
    # (separate from the control plane's), so check per-pool whether an
    # upgrade is scheduled/in-progress.
    pool_updates_json='{}'
    if [ "$hypershift_enabled" = "true" ]; then
      while IFS= read -r pool_id; do
        pool_policy_json=$(ocm get "/api/clusters_mgmt/v1/clusters/$cluster_id/node_pools/$pool_id/upgrade_policies" 2>/dev/null || echo '{}')
        pool_policy_count=$(echo "$pool_policy_json" | jq '.items // [] | length')
        if [ "$pool_policy_count" -gt 0 ]; then
          info=$(echo "$pool_policy_json" | jq -c '.items[0] | {version: (.version // "n/a"), state: (.state.value // "n/a")}')
        else
          info='null'
        fi
        pool_updates_json=$(echo "$pool_updates_json" | jq --arg id "$pool_id" --argjson info "$info" '. + {($id): $info}')
      done < <(echo "$pools_json" | jq -r '.items[].id')
    fi

    echo "$pools_json" | jq -r --argjson updates "$pool_updates_json" --arg hcp "$hypershift_enabled" '
      (["POOL_ID","VERSION","LABELS","TAINTS","UPDATING"] | @tsv),
      (.items[] | . as $item |
        ($updates[$item.id]) as $u |
        [
          .id,
          (.version.raw_id // "n/a"),
          (((.labels // {}) | to_entries | map("\(.key)=\(.value)") | join(",")) as $l | if $l == "" then "-" else $l end),
          (((.taints // []) | map("\(.key)=\(.value):\(.effect)") | join(",")) as $t | if $t == "" then "-" else $t end),
          (if $hcp != "true" then "-" elif $u == null then "No" else "Yes -> \($u.version) (\($u.state))" end)
        ] | @tsv)
    ' | print_table
  fi

  echo
  echo "  Scheduled Update:"
  policy_count=$(echo "$policies_json" | jq '.items // [] | length')
  if [ "$policy_count" -eq 0 ]; then
    echo "    None scheduled."
  else
    echo "$policies_json" | jq -r '
      (["TARGET_VERSION","SCHEDULE_TYPE","NEXT_RUN","STATE"] | @tsv),
      (.items[] | [(.version // "n/a"), .schedule_type, (.next_run // "n/a"), (.state.value // "n/a")] | @tsv)
    ' | print_table
  fi
done < <(echo "$merged_json" | jq -r '
  .[] | [.id, .name, .version, ((.available_upgrades // []) | join(",")), (.hypershift_enabled | tostring)] | @tsv
')

echo
echo "=== Critical/High Vulnerabilities (Insights Advisor) ===" >&2
# Insights Advisor (console.redhat.com) analyzes data uploaded by the
# insights-operator running on each cluster and flags issues/recommendations,
# including ones tied to specific CVEs. A cluster's OCM "external_id" is the
# same UUID Advisor uses as "cluster_id". total_risk: 1=Low 2=Moderate
# 3=High 4=Critical.
ADVISOR_TOKEN=$(ocm token)
while IFS=$'\t' read -r name external_id; do
  echo
  echo "--- $name ---"
  report_json=$(curl -s -H "Authorization: Bearer $ADVISOR_TOKEN" \
    "https://console.redhat.com/api/insights-results-aggregator/v2/cluster/$external_id/reports" 2>/dev/null || echo '{}')
  hits_json=$(echo "$report_json" | jq '[.report.data[]? | select(.total_risk >= 3)]')
  hit_count=$(echo "$hits_json" | jq 'length')
  if [ "$hit_count" -eq 0 ]; then
    echo "    None found."
  else
    echo "$hits_json" | jq -r '
      (["CVE","RISK","DESCRIPTION","RULE_ID"] | @tsv),
      (.[] | [
        (((.description + " " + .rule_id) | capture("(?<c>CVE-[0-9]{4}-[0-9]+)").c?) // "n/a"),
        (if .total_risk == 4 then "CRITICAL" elif .total_risk == 3 then "HIGH" else (.total_risk|tostring) end),
        .description,
        .rule_id
      ] | @tsv)
    ' | print_table
  fi
done < <(echo "$merged_json" | jq -r '.[] | [.name, .external_id] | @tsv')

echo
echo "=== Critical CVEs (OpenShift Vulnerability Service) ===" >&2
# This is the same data shown at:
#   console.redhat.com/openshift/insights/vulnerability/clusters
# It's a real per-cluster CVE scan (based on actual packages/images running
# on each cluster), which is far more accurate than the generic/product-wide
# Red Hat Security Data catalog. Severity buckets: critical/important/moderate/low.
# Only CVEs with a CVSS3 score > 8 are shown.
VULN_TOKEN=$(ocm token)
CVSS3_MIN=8

# Looks up the remediation info for one CVE: the official Red Hat advisory
# link, plus which container image(s) (name/registry/tag) are carrying the
# vulnerable package - the fix is normally to re-pull/update to a newer
# build of that image (or upgrade the cluster, if it's an RHCOS/platform
# component), since customers can't directly patch individual RPMs on ROSA.
print_cve_remediation() {
  local cve="$1"
  local detail_json redhat_url images_json image_count
  local psirt_json ocp_state

  detail_json=$(curl -s -H "Authorization: Bearer $VULN_TOKEN" \
    "https://console.redhat.com/api/ocp-vulnerability/v1/cves/$cve" 2>/dev/null || echo '{}')
  redhat_url=$(echo "$detail_json" | jq -r '.data.redhat_url // "n/a"')

  images_json=$(curl -s -H "Authorization: Bearer $VULN_TOKEN" --get \
    "https://console.redhat.com/api/ocp-vulnerability/v1/cves/$cve/exposed_images" \
    --data-urlencode "limit=20" \
    --data-urlencode "offset=0" 2>/dev/null || echo '{}')
  image_count=$(echo "$images_json" | jq '.data // [] | length')

  # Red Hat's own PSIRT per-product statement (public API, no auth needed) is
  # the authoritative source for whether OCP 4 is actually affected - package
  # scanners often flag a vulnerable library version that's merely present in
  # an image without being used in an exploitable way, which PSIRT accounts for.
  psirt_json=$(curl -s "https://access.redhat.com/hydra/rest/securitydata/cve/$cve.json" 2>/dev/null || echo '{}')
  ocp_state=$(echo "$psirt_json" | jq -r '
    [.package_state[]? | select(.cpe == "cpe:/a:redhat:openshift:4")][0].fix_state // "Unknown / not listed for OCP 4"')

  echo "    How to fix $cve:"
  echo "      Advisory: $redhat_url"
  echo "      Red Hat OCP 4 status (PSIRT): $ocp_state"
  if [ "$ocp_state" = "Not affected" ]; then
    echo "      -> Likely a false positive: the package is present in an image but Red Hat has determined OCP 4 is not exploitable via this CVE."
  fi
  if [ "$image_count" -eq 0 ]; then
    echo "      No specific image identified - check the advisory above for affected packages/fix versions."
  else
    echo "      Update/re-pull these images to a newer build that includes the fix:"
    echo "$images_json" | jq -r '
      (["IMAGE","REGISTRY","CURRENT_VERSION"] | @tsv),
      (.data[] | [.name, .registry, .version] | @tsv)
    ' | print_table
  fi
}

# Prints a CVE table for every cluster at the given severity (e.g. "Critical", "Important"),
# filtered to CVSS3 score > $CVSS3_MIN. When $2 ("with_remediation") is "true",
# also prints how-to-fix info (advisory link + affected images) for each CVE found.
print_cve_section() {
  local severity="$1"
  local with_remediation="${2:-false}"
  while IFS=$'\t' read -r name external_id; do
    echo
    echo "--- $name ---"
    cves_json=$(curl -s -H "Authorization: Bearer $VULN_TOKEN" --get \
      "https://console.redhat.com/api/ocp-vulnerability/v1/clusters/$external_id/cves" \
      --data-urlencode "limit=100" \
      --data-urlencode "offset=0" \
      --data-urlencode "severity=$severity" 2>/dev/null || echo '{}')
    filtered_json=$(echo "$cves_json" | jq --argjson min "$CVSS3_MIN" '[.data[]? | select(.cvss3_score > $min)]')
    cve_count=$(echo "$filtered_json" | jq 'length')
    if [ "$cve_count" -eq 0 ]; then
      echo "    None found."
    else
      echo "$filtered_json" | jq -r '
        (["CVE","CVSS3","PUBLISHED","EXPLOITS","DESCRIPTION"] | @tsv),
        (.[] | [
          .synopsis,
          (.cvss3_score|tostring),
          (.publish_date // "n/a" | split("T")[0]),
          (.exploits|tostring),
          ((.description // "") | if (length > 90) then .[0:87] + "..." else . end)
        ] | @tsv)
      ' | print_table

      if [ "$with_remediation" = "true" ]; then
        while IFS= read -r cve; do
          echo
          print_cve_remediation "$cve"
        done < <(echo "$filtered_json" | jq -r '.[].synopsis')
      fi
    fi
  done < <(echo "$merged_json" | jq -r '.[] | [.name, .external_id] | @tsv')
}

print_cve_section "Critical" "true"

echo
echo "=== Important CVEs (OpenShift Vulnerability Service) ===" >&2
print_cve_section "Important"

#!/usr/bin/env bash
# policies/check.sh - assert the plan's containers against service-images.yaml
# usage: bash policies/check.sh plan.json service-images.yaml
set -u

PLAN="${1:-plan.json}"
MANIFEST="${2:-service-images.yaml}"
violations=0

# manifest_field KEY FIELD -> one field's value from that profile's manifest line
manifest_field() {
  local line
  line=$(grep -E "^  $1:" "$MANIFEST" || true)
  if [ -n "$line" ] && echo "$line" | grep -q "$2:"; then
    echo "$line" | sed -E "s/.*$2:[[:space:]]*\"?([A-Za-z0-9.]+)\"?.*/\1/"
  fi
}

# manifest_ports KEY -> the port list from that profile's manifest line ("3000")
manifest_ports() {
  grep -E "^  $1:" "$MANIFEST" \
    | sed -E "s/.*ports:[[:space:]]*\[([^]]*)\].*/\1/"
}

# env_value KEY VAR -> the VALUE half of the planned "VAR=VALUE" env entry.
# jq: .resource_changes[] walks planned changes; select(...) matches the
# container by its for_each key (.index); .change.after is the planned new
# state; the ( .change.after.env // [] ) guard covers services with no env block.
env_value() {
  jq -r --arg n "$1" --arg v "$2=" '.resource_changes[]
    | select(.type == "docker_container" and .index == $n)
    | ((.change.after.env // [])[]? | select(startswith($v)) | ltrimstr($v))' "$PLAN"
}

# Build the work list from the plan first.
# In a resource_changes entry .index is the for_each key and .name is only the
# resource label ("windows" or "service"). A VERSION= env entry marks a Windows
# (dockur) container. Its profile is the part of the key after the LAST dash,
# because student names cannot contain dashes. Keys "gitea" and "apache" are
# the service lane. Service containers carry no env block at all, hence the
# ( .change.after.env // [] ) guard.
declare -A PROFILE   # for_each key -> manifest profile (win11, win2025, ...)
declare -A CNAME     # for_each key -> container name (.change.after.name)
WIN=""
SVC=""
while IFS=$'\t' read -r n name is_win; do
  CNAME["$n"]="$name"
  if [ "$is_win" = "true" ]; then
    profile="${n##*-}"
    if ! grep -qE "^  $profile:" "$MANIFEST"; then
      echo "VIOLATION: $name: unknown profile \"$profile\" (not in $MANIFEST)"
      violations=$((violations + 1))
      continue
    fi
    PROFILE["$n"]="$profile"
    WIN="$WIN $n"
  elif [ "$n" = "gitea" ] || [ "$n" = "apache" ]; then
    PROFILE["$n"]="$n"
    SVC="$SVC $n"
  fi
done < <(jq -r '.resource_changes[]
  | select(.type == "docker_container")
  | [.index, (.change.after.name // .index),
     (any((.change.after.env // [])[]?; startswith("VERSION=")) | tostring)]
  | @tsv' "$PLAN")

echo "== check 1: Windows containers map the virtualization devices and capability =="
for n in $WIN; do
  cname="${CNAME[$n]}"
  # host_path values of the planned device mappings
  devs=$(jq -r --arg n "$n" '.resource_changes[]
    | select(.type == "docker_container" and .index == $n)
    | ((.change.after.devices // []) | map(.host_path // "") | join(" "))' "$PLAN")
  miss=""
  echo " $devs " | grep -q " /dev/kvm " || miss="$miss /dev/kvm"
  echo " $devs " | grep -q " /dev/net/tun " || miss="$miss /dev/net/tun"
  # capabilities is a Block Set and should arrive as an array, but defend
  # against it serializing as an object: read the first block's add list in
  # either shape so a bad shape reports a named violation instead of a jq error
  net_admin=$(jq -r --arg n "$n" '.resource_changes[]
    | select(.type == "docker_container" and .index == $n)
    | (.change.after.capabilities // []) as $c
    | (if ($c | type) == "array" then ($c[0] // {}) else $c end)
    | ((.add // []) | any(.[]?; (ltrimstr("CAP_")) == "NET_ADMIN"))' "$PLAN")
  [ "$net_admin" = "true" ] || miss="$miss NET_ADMIN"
  if [ -n "$miss" ]; then
    echo "VIOLATION: $cname: missing:$miss"
    violations=$((violations + 1))
  else
    echo "OK: $cname: /dev/kvm and /dev/net/tun mapped, NET_ADMIN granted"
  fi
done

echo "== check 2: VERSION matches the manifest profile =="
for n in $WIN; do
  cname="${CNAME[$n]}"
  profile="${PROFILE[$n]}"
  want=$(manifest_field "$profile" version)   # 11 | 2025
  got=$(env_value "$n" VERSION)
  if [ "$got" != "$want" ]; then
    echo "VIOLATION: $cname: planned VERSION=$got but manifest $profile is version: $want"
    violations=$((violations + 1))
  else
    echo "OK: $cname: VERSION=$got matches manifest $profile"
  fi
done

echo "== check 3: RAM_SIZE and CPU_CORES meet the manifest floors =="
for n in $WIN; do
  cname="${CNAME[$n]}"
  profile="${PROFILE[$n]}"
  ram_min=$(manifest_field "$profile" ram_min)   # e.g. 4G
  cpu_min=$(manifest_field "$profile" cpu_min)   # e.g. 2
  ram=$(env_value "$n" RAM_SIZE)                 # e.g. 4G
  cpu=$(env_value "$n" CPU_CORES)                # e.g. 2
  # strip a trailing G and compare integers; missing or non-numeric values
  # fail the -ge test and get reported like anything below the floor
  bad=""
  if [ -z "$ram" ] || ! [ "${ram%G}" -ge "${ram_min%G}" ] 2>/dev/null; then
    bad="$bad RAM_SIZE=${ram:-unset} (floor $ram_min)"
  fi
  if [ -z "$cpu" ] || ! [ "$cpu" -ge "$cpu_min" ] 2>/dev/null; then
    bad="$bad CPU_CORES=${cpu:-unset} (floor $cpu_min)"
  fi
  if [ -n "$bad" ]; then
    echo "VIOLATION: $cname:$bad"
    violations=$((violations + 1))
  else
    echo "OK: $cname: RAM_SIZE=$ram CPU_CORES=$cpu meet the floors ($ram_min, $cpu_min)"
  fi
done

echo "== check 4: Windows containers publish the guest channels =="
for n in $WIN; do
  cname="${CNAME[$n]}"
  # internal/protocol pairs the guest needs published; external ports are
  # student specific, so the plan is not checked for them
  missing=$(jq -r --arg n "$n" '.resource_changes[]
    | select(.type == "docker_container" and .index == $n)
    | (.change.after.ports // []) as $p
    | [ (if any($p[]?; ((.internal // 0) == 3389 and (.protocol // "") == "tcp"))
           then empty else "3389/tcp" end),
        (if any($p[]?; ((.internal // 0) == 3389 and (.protocol // "") == "udp"))
           then empty else "3389/udp" end),
        (if any($p[]?; ((.internal // 0) == 8006 and (.protocol // "") == "tcp"))
           then empty else "8006/tcp" end) ]
    | join(" ")' "$PLAN")
  if [ -n "$missing" ]; then
    echo "VIOLATION: $cname: missing published channels: $missing"
    violations=$((violations + 1))
  else
    echo "OK: $cname: 3389/tcp 3389/udp 8006/tcp published"
  fi
done

echo "== check 5: services publish their ports and stay off /dev/kvm =="
for n in $SVC; do
  cname="${CNAME[$n]}"
  profile="${PROFILE[$n]}"
  ports=$(manifest_ports "$profile")   # e.g. 3000
  bad=""
  # shellcheck disable=SC2086  # intentional: split "3389, 8006" into words
  for p in ${ports//,/ }; do
    hit=$(jq -r --arg n "$n" --argjson p "$p" '.resource_changes[]
      | select(.type == "docker_container" and .index == $n)
      | ((.change.after.ports // []) | any(.[]?; (.internal // 0) == $p))' "$PLAN")
    [ "$hit" = "true" ] || bad="$bad missing internal $p"
  done
  # the manifest says kvm: false for these images: no /dev/kvm may be mapped,
  # which is the property that lets them run on a GitHub-hosted runner
  kvm=$(jq -r --arg n "$n" '.resource_changes[]
    | select(.type == "docker_container" and .index == $n)
    | ((.change.after.devices // []) | any(.[]?; (.host_path // "") == "/dev/kvm"))' "$PLAN")
  if [ "$kvm" = "true" ]; then
    bad="$bad maps /dev/kvm (manifest kvm: false)"
  fi
  if [ -n "$bad" ]; then
    echo "VIOLATION: $cname:$bad"
    violations=$((violations + 1))
  else
    echo "OK: $cname: internal $ports published, no /dev/kvm mapped"
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "$violations policy violation(s). Failing."
  exit 1
fi
echo "All policy checks passed."

#!/usr/bin/env bash
# tests/smoke.sh - prove the guests and services answer, not just that containers exist
# usage: bash tests/smoke.sh <student_name> [all|vms|services]
#
# Services and Windows VMs have different lifecycles, so they get different
# gates. A service is up in seconds and must answer its port. A Windows VM
# boots from a dockur install ISO and writes its disk over 20-40 minutes, so
# "RDP is not up yet" is normal on a healthy first boot and must not fail the
# run. The Windows gate is health-based: a guest that is installing or booted
# is healthy; only a crash loop or a detected boot failure fails.
set -u

STUDENT="${1:-${TF_VAR_student_name:-}}"
[ -n "$STUDENT" ] || { echo "usage: smoke.sh <student_name> [all|vms|services]" >&2; exit 2; }
MODE="${2:-all}"
FAIL=0
ip=127.0.0.1   # published ports answer on loopback; docker port gives the port number

# One entry per container this lab applies: container name -> probe spec
declare -A PROBES=(
  ["${STUDENT}-win11"]="rdp:3389"
  ["${STUDENT}-win2025"]="rdp:3389"
  ["${STUDENT}-gitea"]="http:3000"
  ["${STUDENT}-apache"]="http:80"
)

# The mode narrows the run list: vms = the two Windows entries,
# services = gitea and apache, all = everything
containers=("${STUDENT}-win11" "${STUDENT}-win2025" "${STUDENT}-gitea" "${STUDENT}-apache")
case "$MODE" in
  all)      ;; # everything
  vms)      containers=("${STUDENT}-win11" "${STUDENT}-win2025") ;;
  services) containers=("${STUDENT}-gitea" "${STUDENT}-apache") ;;
  *) echo "usage: smoke.sh <student_name> [all|vms|services]" >&2; exit 2 ;;
esac

# rdp_probe HOST PORT -> 0 when a booted Windows guest answers the RDP negotiation.
# QEMU's user-mode NAT completes the TCP handshake whether or not the guest's
# RDP service is listening, so nc -z cannot tell "container running" from
# "guest booted". The probe sends a 19-byte TPKT + X.224 Connection Request
# carrying an RDP negotiation request and reads 2 bytes back: a booted Windows
# answers with a Connection Confirm starting 0x03 0x00, an unbooted guest
# answers nothing (the connection just closes). NUL bytes cannot survive in a
# bash variable, so compare the hex text od prints.
rdp_probe() {
  local hex
  hex=$(timeout 8 bash -c '
    exec 3<>"/dev/tcp/$1/$2" || exit 1
    printf "\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00\x00\x00\x00\x00" >&3
    head -c 2 <&3
  ' _ "$1" "$2" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$hex" = "0300" ]
}

# boot_failed NAME -> 0 when dockur/QEMU logged a boot failure: the guest never
# wrote a bootable disk and the UEFI firmware fell back to the install DVD until
# it timed out. A healthy install also logs "BdsDxe: skipped ... HARDDISK" while
# it boots the DVD first, so that is NOT a failure signal. The definitive line is
# "No bootable option or device was found" (present once on a broken guest such
# as a Server 2025 install that never finished, absent on a healthy win11).
boot_failed() {
  docker logs "$1" 2>&1 | grep -aq 'No bootable'
}

# probe KIND PORT -> 0 when a service answers on loopback
probe() {
  case "$1" in
    http) curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:$2/" ;;
    rdp)  rdp_probe 127.0.0.1 "$2" ;;
    *)    return 1 ;;
  esac
}

for name in "${containers[@]}"; do
  pmap="${PROBES[$name]}"    # e.g. rdp:3389
  kind="${pmap%%:*}"         # rdp | http
  internal="${pmap##*:}"     # guest-side port
  echo "== smoke: $name =="

  # 1) container-level reboot detector: status, start time and restart count
  #    stable for 60s. This is the crash/restart loop check for every kind. It
  #    cannot see a QEMU boot loop (the container stays up while the guest
  #    reboots); that is what boot_failed covers for Windows.
  read -r s1 t1 rc1 <<<"$(docker inspect -f '{{.State.Status}} {{.State.StartedAt}} {{.RestartCount}}' "$name" 2>/dev/null)"
  sleep 60
  read -r s2 t2 rc2 <<<"$(docker inspect -f '{{.State.Status}} {{.State.StartedAt}} {{.RestartCount}}' "$name" 2>/dev/null)"
  if [ "$s1" != "running" ] || [ "$s2" != "running" ] \
     || [ "$t1" != "$t2" ] || [ "$rc1" != "$rc2" ]; then
    echo "FAIL: $name: status $s1 -> $s2, started $t1 -> $t2 (reboot loop or crash)"
    FAIL=1
    continue
  fi
  echo "OK: $name: status running, started $t1 stable for 60s"

  # 2) guest/service signal: docker port maps the guest-side port to a
  #    student-chosen host port, so the script never hardcodes external ports
  hp=$(docker port "$name" "$internal/tcp" 2>/dev/null | head -n 1)
  port="${hp##*:}"           # host port = number after the last colon

  if [ "$kind" = "http" ]; then
    # Services must answer their port, twice (the second probe catches a
    # service that came up then died).
    if [ -z "$port" ] || ! probe "$kind" "$port"; then
      echo "FAIL: $name: $ip:$port never answered (container running != service up)"
      FAIL=1
      continue
    fi
    sleep 30
    if ! probe "$kind" "$port"; then
      echo "FAIL: $name: $ip:$port answered, then went away (flapping)"
      FAIL=1
      continue
    fi
    echo "OK: $name: $ip:$port answered and still answering"
    continue
  fi

  # Windows: health-based gate. A boot failure is a hard fail; installing and
  # booted are both healthy. This is the difference from a service: a guest mid
  # install has no RDP yet and that is fine.
  if boot_failed "$name"; then
    echo "FAIL: $name: boot failure -- 'No bootable option or device was found'. The install never wrote a bootable disk."
    FAIL=1
    continue
  fi
  if [ -n "$port" ] && rdp_probe "$ip" "$port"; then
    # Booted and answering RDP. Re-probe once to catch a flapping boot loop.
    sleep 30
    if ! rdp_probe "$ip" "$port"; then
      echo "FAIL: $name: $ip:$port answered RDP, then went away (flapping boot loop)"
      FAIL=1
      continue
    fi
    echo "OK: $name: guest booted, RDP answering on $ip:$port"
    continue
  fi
  echo "OK: $name: first-boot install in progress (no boot error, RDP not up yet) -- healthy"
done

if [ "$FAIL" -ne 0 ]; then
  echo "Smoke tests failed."
  exit 1
fi
echo "All smoke tests passed."

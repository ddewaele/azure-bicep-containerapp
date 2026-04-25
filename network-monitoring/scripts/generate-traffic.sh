#!/usr/bin/env bash
# =============================================================================
# Generate interesting traffic between vm1 and vm2 so NSG flow logs and
# Traffic Analytics have data to show.
#
# Run on vm1 (SSH via Bastion). Loops every 30s by default, press Ctrl-C to stop.
#
#   ./generate-traffic.sh            # run loop indefinitely
#   ./generate-traffic.sh --once     # single pass
# =============================================================================
set -u

VM2_IP="${VM2_IP:-10.50.2.10}"

run_once() {
  echo "=== $(date -Is) ==="

  echo "[vm1 → vm2:22]  TCP SSH     (expected: ALLOW  — nsg-vm2 allow-vnet-ssh)"
  timeout 5 bash -c "cat < /dev/tcp/$VM2_IP/22" >/dev/null 2>&1 && echo "  OK" || echo "  FAIL"

  echo "[vm1 → vm2:80]  TCP HTTP    (expected: DENY   — no HTTP allow rule in nsg-vm2)"
  timeout 5 bash -c "cat < /dev/tcp/$VM2_IP/80" >/dev/null 2>&1 && echo "  OK" || echo "  FAIL (blocked)"

  echo "[vm1 → vm2   ]  ICMP ping   (expected: ALLOW  — nsg-vm2 allow-vm1subnet-icmp)"
  ping -c 2 -W 2 "$VM2_IP" >/dev/null 2>&1 && echo "  OK" || echo "  FAIL"

  echo "[vm1 → Internet] HTTPS      (expected: ALLOW  — outbound unrestricted)"
  curl -sS --max-time 5 -o /dev/null -w "  HTTP %{http_code}\n" https://example.com || echo "  FAIL"

  echo
}

if [ "${1:-}" = "--once" ]; then
  run_once
else
  while true; do
    run_once
    sleep 30
  done
fi

#!/usr/bin/env bash
# extend-network-range.sh — extend a Hetzner Cloud Network's ip_range while servers / load balancers are attached.
#
# Hetzner refuses POST /networks/{id}/actions/change_ip_range with service_error "network has attached
# resources" as soon as one server is attached (undocumented; verified 2026-10-03). This script therefore:
#   1. records every member (servers with their IP + alias IPs, load balancers with their IP and targets)
#      to a state file, so a crash mid-way can be recovered by hand;
#   2. detaches every load balancer (Hetzner drops its private-IP targets on detach) and every server;
#   3. extends the range;
#   4. re-attaches every server and load balancer with the IP it had, and re-adds the LB targets.
# Private-network connectivity is down for the whole window; k3s nodes go NotReady and recover on their own.
# A re-attached server gets the new range's route from DHCP, so no reboot is needed.
#
# Usage:  HCLOUD_TOKEN=... extend-network-range.sh <network name> <new ip_range> [--yes]
# Without --yes it only prints the plan.
set -euo pipefail
NET_NAME=${1:?network name}; NEW_RANGE=${2:?new ip_range}; YES=${3:-}
H=https://api.hetzner.cloud/v1
STATE_DIR=${STATE_DIR:-$PWD}
api() { curl -sS -m 60 -H "Authorization: Bearer ${HCLOUD_TOKEN:?HCLOUD_TOKEN is required}" -H "Content-Type: application/json" "$@"; }
py() { python3 -c "$@"; }
ts() { date -u +%H:%M:%S; }
wait_action() {
  local id=$1 st
  for _ in $(seq 1 150); do
    st=$(api "$H/actions/$id" | py 'import sys,json; print(json.load(sys.stdin)["action"]["status"])')
    case $st in success) return 0;; error) echo "action $id failed:"; api "$H/actions/$id"; return 1;; esac
    sleep 2
  done
  echo "action $id timed out"; return 1
}
act() { # act <path> <json>: POST, then wait for the action
  local out id
  out=$(api -X POST "$H$1" -d "$2")
  id=$(echo "$out" | py 'import sys,json; d=json.load(sys.stdin); print(d["action"]["id"] if "action" in d else "")')
  [ -n "$id" ] || { echo "request $1 failed: $out"; return 1; }
  wait_action "$id"
}
members_json() { api "$H/networks/$NID/members?per_page=50" | py 'import sys,json; print(json.dumps(json.load(sys.stdin)["members"]))'; }

NID=$(api "$H/networks?name=$NET_NAME" | py 'import sys,json; n=json.load(sys.stdin)["networks"]; print(n[0]["id"] if n else "")')
[ -n "$NID" ] || { echo "network '$NET_NAME' not found"; exit 1; }
CUR=$(api "$H/networks/$NID" | py 'import sys,json; print(json.load(sys.stdin)["network"]["ip_range"])')

# Wait until every member is in a steady state before touching anything.
for _ in $(seq 1 60); do
  members_json | py 'import sys,json; sys.exit(0 if all(m["status"]=="ok" for m in json.load(sys.stdin)) else 1)' && break
  echo "$(ts) waiting for members to settle..."; sleep 5
done

STATE="$STATE_DIR/extend-$NET_NAME-$(date -u +%Y%m%dT%H%M%SZ).json"
members_json | py '
import sys, json, os, urllib.request
H = "https://api.hetzner.cloud/v1"; tok = os.environ["HCLOUD_TOKEN"]
def get(p):
    r = urllib.request.Request(H + p, headers={"Authorization": "Bearer " + tok}); return json.load(urllib.request.urlopen(r, timeout=60))
ms = json.load(sys.stdin); out = {"network_id": int(sys.argv[1]), "members": []}
for m in ms:
    e = {"type": m["type"], "id": m["id"], "ip": m["ip"], "alias_ips": m.get("alias_ips") or []}
    if m["type"] == "server":
        e["name"] = get("/servers/%d" % m["id"])["server"]["name"]
    else:
        lb = get("/load_balancers/%d" % m["id"])["load_balancer"]; e["name"] = lb["name"]
        e["targets"] = [{"type": t["type"], "server": t.get("server", {}).get("id"), "label_selector": (t.get("label_selector") or {}).get("selector"), "ip": (t.get("ip") or {}).get("ip"), "use_private_ip": t.get("use_private_ip", False)} for t in lb["targets"]]
    out["members"].append(e)
json.dump(out, open(sys.argv[2], "w"), indent=2)
' "$NID" "$STATE"
chmod 600 "$STATE"
echo "network $NET_NAME ($NID): $CUR -> $NEW_RANGE"
echo "state file: $STATE"
py '
import sys, json
for m in json.load(open(sys.argv[1]))["members"]:
    extra = (" targets=%s" % m["targets"]) if m["type"] == "load_balancer" else ((" alias_ips=%s" % m["alias_ips"]) if m["alias_ips"] else "")
    print("  %-14s %-10s %-30s %s%s" % (m["type"], m["id"], m["name"], m["ip"], extra))
' "$STATE"
[ "$YES" = "--yes" ] || { echo "dry run — pass --yes to execute"; exit 0; }

T0=$(date +%s)
mapfile -t LBS < <(py 'import sys,json; [print(m["id"]) for m in json.load(open(sys.argv[1]))["members"] if m["type"]=="load_balancer"]' "$STATE")
mapfile -t SRVS < <(py 'import sys,json; [print(m["id"]) for m in json.load(open(sys.argv[1]))["members"] if m["type"]=="server"]' "$STATE")
for lb in "${LBS[@]}"; do echo "$(ts) detaching load balancer $lb"; act "/load_balancers/$lb/actions/detach_from_network" "{\"network\":$NID}"; done
for s in "${SRVS[@]}"; do echo "$(ts) detaching server $s"; act "/servers/$s/actions/detach_from_network" "{\"network\":$NID}"; done
for _ in $(seq 1 60); do [ "$(members_json)" = "[]" ] && break; sleep 2; done
echo "$(ts) extending $CUR -> $NEW_RANGE"; act "/networks/$NID/actions/change_ip_range" "{\"ip_range\":\"$NEW_RANGE\"}"
T1=$(date +%s)
for s in "${SRVS[@]}"; do
  ip=$(py 'import sys,json; print([m for m in json.load(open(sys.argv[1]))["members"] if m["id"]==int(sys.argv[2])][0]["ip"])' "$STATE" "$s")
  aliases=$(py 'import sys,json; print(json.dumps([m for m in json.load(open(sys.argv[1]))["members"] if m["id"]==int(sys.argv[2])][0]["alias_ips"]))' "$STATE" "$s")
  echo "$(ts) re-attaching server $s as $ip"; act "/servers/$s/actions/attach_to_network" "{\"network\":$NID,\"ip\":\"$ip\",\"alias_ips\":$aliases}"
done
for lb in "${LBS[@]}"; do
  ip=$(py 'import sys,json; print([m for m in json.load(open(sys.argv[1]))["members"] if m["id"]==int(sys.argv[2])][0]["ip"])' "$STATE" "$lb")
  echo "$(ts) re-attaching load balancer $lb as $ip"; act "/load_balancers/$lb/actions/attach_to_network" "{\"network\":$NID,\"ip\":\"$ip\"}"
  py 'import sys,json; [print(json.dumps(t)) for t in [m for m in json.load(open(sys.argv[1]))["members"] if m["id"]==int(sys.argv[2])][0]["targets"]]' "$STATE" "$lb" | while read -r t; do
    payload=$(echo "$t" | py 'import sys,json; t=json.load(sys.stdin); p={"type":t["type"],"use_private_ip":t["use_private_ip"]}
if t["type"]=="server": p["server"]={"id":t["server"]}
elif t["type"]=="label_selector": p["label_selector"]={"selector":t["label_selector"]}
elif t["type"]=="ip": p["ip"]={"ip":t["ip"]}; p.pop("use_private_ip")
print(json.dumps(p))')
    echo "$(ts) re-adding target $payload"; act "/load_balancers/$lb/actions/add_target" "$payload"
  done
done
T2=$(date +%s)
echo "$(ts) done: detach+extend $((T1-T0)) s, re-attach $((T2-T1)) s, total window $((T2-T0)) s"
echo "network now: $(api "$H/networks/$NID" | py 'import sys,json; print(json.load(sys.stdin)["network"]["ip_range"])')"
echo "members now: $(members_json | py 'import sys,json; print([(m["type"], m["id"], m["ip"], m["status"]) for m in json.load(sys.stdin)])')"

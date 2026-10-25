#!/usr/bin/env bash
# ai-services.sh — exclusive manager for the GPU AI services on this machine.
#
#   comfyui       ComfyUI              http://0.0.0.0:18188
#   local-llm     local LLM            http://0.0.0.0:11434
#   strata-iq3_s  Strata               http://0.0.0.0:18182
#
# Only one may run at a time: starting one stops the others first.
#
# Every service binds 0.0.0.0, so it is reachable on loopback, on tailscale0 and on the LAN.
# ufw is the thing deciding who actually gets in (INPUT policy DROP, /etc/default/ufw): the LAN is
# already closed; the tailnet needs explicit allow rules for the service ports.
#
# Usage:
#   ai-services.sh status
#   ai-services.sh tailnet      # the tailnet URLs to type on another machine
#   ai-services.sh toggle <id>
#   ai-services.sh start  <id>
#   ai-services.sh stop   <id>
set -u

IDS=(comfyui local-llm strata-iq3_s)

unit_of() {
  case "$1" in
    comfyui)      echo comfyui.service ;;
    local-llm)    echo local-llm.service ;;
    strata-iq3_s) echo strata-iq3_s.service ;;
  esac
}

port_of() {
  case "$1" in
    comfyui)      echo 18188 ;;
    local-llm)    echo 11434 ;;
    strata-iq3_s) echo 18182 ;;
  esac
}

# Distinctive cmdline pattern for unmanaged instances ("" = port only).
pattern_of() {
  case "$1" in
    strata-iq3_s) echo 'packs/iq3_s|strata-iq3_s\.json' ;;
    *)            echo '' ;;
  esac
}

# A listening socket means the service is up: these units bind 0.0.0.0, so the match has to accept
# the wildcard forms too (ss prints them as "*:port" / "0.0.0.0:port").  The port number is part of
# the match because ss also prints a peer column ("0.0.0.0:*") that a bare address would hit.
port_listening() {
  ss -ltnH "sport = :$1" 2>/dev/null \
    | grep -qE "(^|[[:space:]])(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\[::\]|\*):$1([[:space:]]|$)"
}

tailnet_ip() { tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]'; }

# "tailnet <tailnet-ip>" for the panel: the address other machines on the tailnet use.
tailnet_line() {
  local ip
  ip=$(tailnet_ip)
  printf 'tailnet %s\n' "${ip:-down}"
}

manual_running() {
  local p
  p=$(pattern_of "$1")
  [ -n "$p" ] && pgrep -f "$p" >/dev/null 2>&1
}

# True once the service is actually serving requests (not just spawned).
ready_of() {
  case "$1" in
    strata-iq3_s)
      curl -sf --max-time 1 "http://127.0.0.1:$(port_of "$1")/health" 2>/dev/null | grep -q '"loaded": *true'
      ;;
    comfyui)
      curl -sf --max-time 1 http://127.0.0.1:18188/system_stats >/dev/null 2>&1
      ;;
    *)
      return 0
      ;;
  esac
}

state_of() {
  local id=$1 s
  s=$(systemctl --user is-active "$(unit_of "$id")" 2>/dev/null || true)
  case "$s" in
    failed) echo failed; return ;;
  esac
  if [ "$s" = active ]; then
    if ready_of "$id"; then echo running; else echo starting; fi
    return
  fi
  if [ "$s" = activating ]; then echo starting; return; fi
  # Not managed by systemd: maybe an instance was started by hand.
  if port_listening "$(port_of "$id")" || manual_running "$id"; then
    echo running
  else
    echo stopped
  fi
}

stop_one() {
  local id=$1 p port
  p=$(pattern_of "$id"); port=$(port_of "$id")
  systemctl --user stop "$(unit_of "$id")" >/dev/null 2>&1 || true
  if [ -n "$p" ]; then pkill -f "$p" >/dev/null 2>&1 || true; fi
  if port_listening "$port"; then
    fuser -k -TERM "${port}/tcp" >/dev/null 2>&1 || true
    sleep 0.5
    if port_listening "$port"; then fuser -k -KILL "${port}/tcp" >/dev/null 2>&1 || true; fi
  fi
}

start_one() {
  local id=$1 other
  for other in "${IDS[@]}"; do
    [ "$other" = "$id" ] && continue
    stop_one "$other"
  done
  systemctl --user start "$(unit_of "$id")" >/dev/null 2>&1
}

# The GPU power cap line for the panel's switcher. Reading nvidia-smi needs no root; changing it
# goes through /usr/local/bin/omarchy-gpu-power (install that helper on this machine first),
# which the panel runs with pkexec - that shows the usual password dialog.
gpu_power_of() {
  local cap draw boot bin=/usr/local/bin/omarchy-gpu-power
  cap=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d. -f1)
  draw=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d. -f1)
  boot=$(cat /var/lib/omarchy/gpu-power/cap 2>/dev/null || echo default)
  printf 'gpu-power %s %s %s %s\n' "${cap:-?}" "${draw:-?}" "$boot" "$([ -x "$bin" ] && echo yes || echo no)"
}

# The CPU package limits line for the panel's switcher. PL1/PL2 are world-readable, so the bar can
# show them without a password; only changing them runs pkexec (password dialog) through
# /usr/local/bin/omarchy-cpu-power. Live package watts are root-only (energy_uj), so they are not shown.
cpu_power_of() {
  local z= pl1='?' pl2='?' saved=default bin=/usr/local/bin/omarchy-cpu-power
  for d in /sys/class/powercap/intel-rapl*; do
    [ -f "$d/name" ] || continue
    case "$(cat "$d/name" 2>/dev/null)" in package*) z=$d; break ;; esac
  done
  if [ -n "$z" ] && [ -r "$z/constraint_0_power_limit_uw" ]; then
    pl1=$(( $(cat "$z/constraint_0_power_limit_uw") / 1000000 ))
    pl2=$(( $(cat "$z/constraint_1_power_limit_uw") / 1000000 ))
  fi
  saved=$(cat /var/lib/omarchy/cpu-power/cap 2>/dev/null || echo default)
  printf 'cpu-power %s %s %s %s\n' "$pl1" "$pl2" "$saved" "$([ -x "$bin" ] && echo yes || echo no)"
}

case "${1:-status}" in
  status)
    for id in "${IDS[@]}"; do printf '%s %s\n' "$id" "$(state_of "$id")"; done
    tailnet_line
    gpu_power_of
    cpu_power_of
    ;;
  tailnet)
    ip=$(tailnet_ip)
    if [ -z "$ip" ]; then echo "tailscale has no address on this machine" >&2; exit 1; fi
    for id in "${IDS[@]}"; do printf '%s http://%s:%s\n' "$id" "$ip" "$(port_of "$id")"; done
    ;;
  start)
    start_one "${2:?missing service id}"
    ;;
  stop)
    stop_one "${2:?missing service id}"
    ;;
  toggle)
    id=${2:?missing service id}
    s=$(state_of "$id")
    if [ "$s" = stopped ] || [ "$s" = failed ]; then start_one "$id"; else stop_one "$id"; fi
    ;;
  *)
    echo "usage: $0 {status|tailnet|start|stop|toggle} <id>" >&2
    exit 2
    ;;
esac

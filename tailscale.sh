#!/bin/sh
# Copyright (c) 2024 Fluent Networks Pty Ltd & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

# If arguments are passed, execute tailscale with those arguments
if [ $# -gt 0 ]; then
  exec /usr/local/bin/tailscale "$@"
fi

set -e

# Local change: log to stdout/stderr so RouterOS (logging=yes) shows it in /log,
# instead of upstream's startup.log in the state dir.
echo "$(date -Iseconds) tailscale.sh starting"

# Ensure TUN device exists (best-effort)
if [ ! -e /dev/net/tun ]; then
  echo "Creating TUN device (best-effort)..."
  mkdir -p /dev/net || true
  mknod /dev/net/tun c 10 200 2>/dev/null || echo "Warning: Could not create /dev/net/tun; ensure host provides it"
  chmod 600 /dev/net/tun 2>/dev/null || true
fi

# Verify iptables availability (warn only on MikroTik; netfilter-mode may be off)
if ! command -v iptables >/dev/null 2>&1; then
  echo "Warning: iptables not found in PATH (ok if --netfilter-mode=off)"
  echo "Current PATH: $PATH"
fi

# Enable IP forwarding - requires root privileges
if [ "$(id -u)" = "0" ]; then
  echo 'Enabling IP forwarding...'
  
  # Try to enable IP forwarding directly, but don't fail if it doesn't work
  # This will fail in Docker unless --privileged is used
  if [ -w /proc/sys/net/ipv4/ip_forward ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "Warning: Could not enable IPv4 forwarding"
  else
    echo "Note: /proc/sys/net/ipv4/ip_forward is read-only, IP forwarding must be enabled on the host"
  fi
  
  if [ -w /proc/sys/net/ipv6/conf/all/forwarding ]; then
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo "Warning: Could not enable IPv6 forwarding"
  else
    echo "Note: /proc/sys/net/ipv6/conf/all/forwarding is read-only, IP forwarding must be enabled on the host"
  fi
  
  # Create sysctl.d directory if it doesn't exist and is writable
  if [ -w /etc ] && [ ! -d /etc/sysctl.d ]; then
    mkdir -p /etc/sysctl.d
  fi
  
  # Write to sysctl.d if it exists and is writable
  if [ -d /etc/sysctl.d ] && [ -w /etc/sysctl.d ]; then
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale.conf
    # Only run sysctl if it exists
    if command -v sysctl >/dev/null 2>&1; then
      sysctl -p /etc/sysctl.d/99-tailscale.conf 2>/dev/null || echo "Note: Could not apply sysctl settings, IP forwarding must be enabled on the host"
    fi
  fi
else
  echo "Warning: Not running as root, skipping IP forwarding configuration"
fi

# Install routes if specified - requires root privileges
if [ -n "${ADVERTISE_ROUTES}" ] && [ "$(id -u)" = "0" ]; then
  echo "Setting up routes: ${ADVERTISE_ROUTES}"
  # Use a more compatible syntax for reading the array
  OLD_IFS="$IFS"
  IFS=","
  for s in ${ADVERTISE_ROUTES}; do
    if [ -n "${CONTAINER_GATEWAY}" ]; then
      echo "Adding route: $s via ${CONTAINER_GATEWAY}"
      ip route add "$s" via "${CONTAINER_GATEWAY}" 2>/dev/null || echo "Note: Failed to add route $s - this may be normal in Docker"
    fi
  done
  IFS="$OLD_IFS"
elif [ -n "${ADVERTISE_ROUTES}" ]; then
  echo "Warning: Not running as root, skipping route configuration"
fi

# Set login server for tailscale
if [ -z "$LOGIN_SERVER" ]; then
  LOGIN_SERVER=https://controlplane.tailscale.com
fi

# Run any custom startup script if provided
if [ -n "$STARTUP_SCRIPT" ] && [ -f "$STARTUP_SCRIPT" ]; then
  echo "Running startup script: $STARTUP_SCRIPT"
  sh "$STARTUP_SCRIPT" || exit $?
fi

# Create state directory if it doesn't exist
mkdir -p /var/lib/tailscale

# Print environment information for debugging
echo "Environment information:"
echo "PATH: $PATH"
echo "iptables location: $(which iptables 2>/dev/null || echo 'not found')"
echo "ip6tables location: $(which ip6tables 2>/dev/null || echo 'not found')"
echo "TUN device: $(ls -la /dev/net/tun 2>/dev/null || echo 'not found')"
echo "IP forwarding status:"
cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "Cannot read IPv4 forwarding status"
cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo "Cannot read IPv6 forwarding status"

# Start tailscaled
echo "Starting tailscaled..."
/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state ${TAILSCALED_ARGS} &
TAILSCALED_PID=$!

# Wait for tailscaled to start
sleep 2

# If tailscaled exited early, dump a hint to the log
if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
  echo "tailscaled exited early; see output above" >&2
fi

# Bring tailscale up
echo "Bringing tailscale up..."
if [ -n "${AUTH_KEY}" ]; then
  # Use auth key if provided
  /usr/local/bin/tailscale up \
    --reset \
    --authkey="${AUTH_KEY}" \
    --login-server "${LOGIN_SERVER}" \
    ${ADVERTISE_ROUTES:+--advertise-routes="${ADVERTISE_ROUTES}"} \
    ${TAILSCALE_ARGS} || echo "Warning: tailscale up with AUTH_KEY returned non-zero; continuing"
else
  # Interactive login if no auth key
  # If state already exists, this should be idempotent. Ignore failure to avoid exit.
  /usr/local/bin/tailscale up \
    --reset \
    --login-server "${LOGIN_SERVER}" \
    ${ADVERTISE_ROUTES:+--advertise-routes="${ADVERTISE_ROUTES}"} \
    ${TAILSCALE_ARGS} || echo "Warning: tailscale up returned non-zero (likely awaiting interactive auth); continuing"
fi

# Local change: prefs that `tailscale up` does not accept (e.g. peer relay),
# re-applied on every start because `up --reset` above clears them.
if [ -n "${TAILSCALE_SET_ARGS}" ]; then
  /usr/local/bin/tailscale set ${TAILSCALE_SET_ARGS} && echo "tailscale set ${TAILSCALE_SET_ARGS}" ||
    echo "Warning: tailscale set ${TAILSCALE_SET_ARGS} failed"
fi

# Local change: prefixes the host router reaches by other means (e.g. WireGuard)
# must not follow routes accepted from the tailnet (table 52), otherwise replies to
# hosts there leave via tailscale0 and forwarded traffic fails rp_filter.
if [ -n "${MAIN_TABLE_PREFIXES}" ]; then
  for p in $(echo "${MAIN_TABLE_PREFIXES}" | tr ',' ' '); do
    ip rule add to "$p" lookup main priority 5200 2>/dev/null || true
  done
  echo "Main-table rules for: ${MAIN_TABLE_PREFIXES}"
fi

# Local change: masquerade traffic routed into the tailnet. RouterOS sends its own
# traffic (and later the LAN's) to the container with a non-tailnet source IP,
# which peers would drop, so rewrite it to this node's 100.x address.
if [ "${MASQUERADE_TAILNET:-1}" = "1" ]; then
  for ipt in iptables iptables-legacy; do
    if $ipt -t nat -C POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null ||
       $ipt -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE; then
      echo "MASQUERADE on tailscale0 via $ipt"
      break
    fi
    echo "Warning: $ipt could not add MASQUERADE rule"
  done
fi

# Local change: clamp MSS of SYNs forwarded into the tailnet to its MTU (1280 -> 1240).
# Hosts behind a remote subnet router that never receive ICMP frag-needed would
# otherwise keep sending full-size segments that are dropped at that router's tailscale0.
if [ "${CLAMP_MSS_TAILNET:-1}" = "1" ]; then
  for ipt in iptables iptables-legacy; do
    if $ipt -t mangle -C FORWARD -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||
       $ipt -t mangle -A FORWARD -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; then
      echo "MSS clamp on tailscale0 via $ipt"
      break
    fi
    echo "Warning: $ipt could not add MSS clamp rule"
  done
fi

# Local change: SNAT tailnet -> advertised subnets (tailscaled's own snat-subnet-routes
# is inactive with --netfilter-mode=off). LAN hosts then reply to this container
# directly instead of via their default gateway, keeping the path symmetric.
if [ -n "${ADVERTISE_ROUTES}" ] && [ "${SNAT_SUBNET_ROUTES:-1}" = "1" ]; then
  for ipt in iptables iptables-legacy; do
    if $ipt -t nat -C POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE 2>/dev/null ||
       $ipt -t nat -A POSTROUTING -s 100.64.0.0/10 ! -o tailscale0 -j MASQUERADE; then
      echo "SNAT for subnet routes via $ipt"
      break
    fi
    echo "Warning: $ipt could not add subnet SNAT rule"
  done
fi

# Local change: export routes accepted from the tailnet (tailscaled's table 52)
# to the host router over BGP, so RouterOS learns them like a client would.
# Enabled by BGP_PEER (e.g. 192.168.88.1), BGP_PEER_AS and BGP_LOCAL_AS.
if [ -n "${BGP_PEER}" ] && command -v bird >/dev/null 2>&1; then
  ROUTER_ID=$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}')
  cat > /etc/bird.conf <<EOF
log stderr all;
router id ${ROUTER_ID};

protocol device { scan time 10; }

ipv4 table tailnet;

# Learn tailscaled's routes; skip tailnet node IPs and quad-100, keep only unicast.
protocol kernel ts52 {
  kernel table 52;
  learn;
  scan time 10;
  ipv4 {
    table tailnet;
    import filter {
      if net ~ [ 100.64.0.0/10+, 100.100.100.100/32 ] then reject;
      if dest != RTD_UNICAST then reject;
      accept;
    };
    export none;
  };
}

protocol bgp routeros {
  local as ${BGP_LOCAL_AS:-65100};
  neighbor ${BGP_PEER} as ${BGP_PEER_AS};
  ipv4 {
    table tailnet;
    import none;
    export all;
    next hop self;
  };
}
EOF
  echo "Starting BIRD (router id ${ROUTER_ID}, peer ${BGP_PEER} AS ${BGP_PEER_AS})"
  mkdir -p /run/bird
  bird -f -c /etc/bird.conf -s /run/bird/bird.ctl &
fi

echo "Tailscale started successfully!"

# Keep the container running
wait $TAILSCALED_PID

# routeros-tailscale-bgp: first-time setup on RouterOS 7.
#
# Assumes the default configuration naming (LAN bridge "bridge", interface
# lists LAN/WAN), the container package installed, device-mode container=yes,
# and the image already copied to the disk, e.g. usb1/tailscale-arm64.tar.
# Edit the variables below, then: /import routeros/setup.rsc
# (copy the file to the router first). Everything it adds carries the comment
# "tailscale-bgp", so you can find and remove it later.

:local lanBridge "bridge"
:local lanNet "192.168.88.0/24"
:local lanLen "24"
:local routerIp "192.168.88.1"
:local ctIp "192.168.88.49"
:local disk "usb1"
:local image "tailscale-arm64.tar"
:local hostname "routeros"
:local routerAs "65012"
:local ctAs "65100"
:local wgPort "41641"
:local tag "tailscale-bgp"

# Container network, state mount and environment
/interface/veth/add name=veth-tailscale address=($ctIp . "/" . $lanLen) gateway=$routerIp comment=$tag
/interface/bridge/port/add bridge=$lanBridge interface=veth-tailscale comment=$tag

/container/mounts/add list=tailscale_state src=("/" . $disk . "/tailscale-state") dst=/var/lib/tailscale comment=$tag

/container/envs/add list=tailscale key=TAILSCALE_ARGS value=("--hostname=" . $hostname . " --accept-routes=true --accept-dns=false --netfilter-mode=off")
/container/envs/add list=tailscale key=ADVERTISE_ROUTES value=$lanNet
/container/envs/add list=tailscale key=TAILSCALED_ARGS value=("--port=" . $wgPort)
/container/envs/add list=tailscale key=BGP_PEER value=$routerIp
/container/envs/add list=tailscale key=BGP_PEER_AS value=$routerAs
/container/envs/add list=tailscale key=BGP_LOCAL_AS value=$ctAs

/container/add name=tailscale file=("/" . $disk . "/" . $image) interface=veth-tailscale \
    envlists=tailscale mountlists=tailscale_state root-dir=("/" . $disk . "/tailscale") \
    dns=$routerIp start-on-boot=yes logging=yes comment=$tag

# Tailnet node addresses go to the container
/ip/route/add dst-address=100.64.0.0/10 gateway=$ctIp comment=$tag

# BGP: accept tailnet subnet routes, announce nothing back
/routing/filter/rule/add chain=tailscale-in comment=$tag \
    rule="if (dst == 0.0.0.0/0 || dst in 100.64.0.0/10) { reject }"
/routing/filter/rule/add chain=tailscale-in comment=$tag \
    rule=("if (dst in " . $lanNet . ") { reject }")
/routing/filter/rule/add chain=tailscale-in comment=$tag \
    rule="set distance 25; accept"
/routing/filter/rule/add chain=tailscale-out comment=$tag rule="reject"

:if ([:len [/routing/bgp/instance/find]] = 0) do={
    /routing/bgp/instance/add name=default as=$routerAs router-id=$routerIp comment=$tag
}
:local inst [/routing/bgp/instance/get ([/routing/bgp/instance/find]->0) name]
/routing/bgp/connection/add name=tailscale-container instance=$inst as=$routerAs \
    local.address=$routerIp local.role=ebgp remote.address=($ctIp . "/32") remote.as=$ctAs \
    connect=yes listen=yes input.filter=tailscale-in output.filter-chain=tailscale-out \
    routing-table=main comment=$tag

# Firewall: stop the container's own packets from being routed back to it
:local fwd [/ip/firewall/filter/find where chain=forward]
:if ([:len $fwd] > 0) do={
    /ip/firewall/filter/add chain=forward action=drop src-address=$ctIp in-interface=$lanBridge \
        out-interface=$lanBridge comment=($tag . ": no hairpin back to itself") place-before=($fwd->0)
} else={
    /ip/firewall/filter/add chain=forward action=drop src-address=$ctIp in-interface=$lanBridge \
        out-interface=$lanBridge comment=($tag . ": no hairpin back to itself")
}

# NAT: fixed WireGuard port in both directions, so peers can connect directly
/ip/firewall/nat/add chain=dstnat action=dst-nat in-interface-list=WAN protocol=udp dst-port=$wgPort \
    to-addresses=$ctIp to-ports=$wgPort comment=$tag
:local snat [/ip/firewall/nat/find where chain=srcnat]
:if ([:len $snat] > 0) do={
    /ip/firewall/nat/add chain=srcnat action=masquerade out-interface-list=WAN protocol=udp \
        src-address=$ctIp src-port=$wgPort to-ports=$wgPort comment=$tag place-before=($snat->0)
} else={
    /ip/firewall/nat/add chain=srcnat action=masquerade out-interface-list=WAN protocol=udp \
        src-address=$ctIp src-port=$wgPort to-ports=$wgPort comment=$tag
}

# Start once the image has been extracted (up to 5 minutes)
:local started false
:local tries 0
:while (!$started && $tries < 60) do={
    :delay 5s
    :set tries ($tries + 1)
    :do {
        /container/start [find name=tailscale]
        :set started true
    } on-error={}
}
:if ($started) do={
    :put "tailscale container started. Open the login URL shown in /log, then approve the subnet route in the admin console."
} else={
    :put "tailscale container did not start yet; check /container/print and start it by hand."
}

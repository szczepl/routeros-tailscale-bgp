# routeros-tailscale-bgp: replace the running container with a new image.
#
# Copy the new tar to the disk first (same name as below). The node state is on
# the mount, so no new login is needed. While the container is down the router
# has no tailnet routes: don't run this over a connection that uses them.
# /import routeros/upgrade.rsc

:local disk "usb1"
:local image "tailscale-arm64.tar"    ;# tailscale-arm.tar on 32-bit ARM, tailscale-amd64.tar on CHR/x86
:local routerIp "192.168.88.1"

:local ct [/container/find where name=tailscale]
:local comment [/container/get $ct comment]
/container/stop $ct
:local tries 0
:while ([/container/get $ct running] && $tries < 30) do={
    :delay 1s
    :set tries ($tries + 1)
}
/container/remove $ct

/container/add name=tailscale file=("/" . $disk . "/" . $image) interface=veth-tailscale \
    envlists=tailscale mountlists=tailscale_state root-dir=("/" . $disk . "/tailscale") \
    dns=$routerIp start-on-boot=yes logging=yes comment=$comment

:local started false
:set tries 0
:while (!$started && $tries < 60) do={
    :delay 5s
    :set tries ($tries + 1)
    :do {
        /container/start [find name=tailscale]
        :set started true
    } on-error={}
}
:if ($started) do={ :put "tailscale container started" } else={ :put "start it by hand: /container/start [find name=tailscale]" }

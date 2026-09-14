# cluster

For details, check out the article [On Building A Cluster From Linux Primitives](https://benjamintoll.com/2026/09/15/on-building-a-cluster-from-linux-primitives/) and [On cgroups](https://benjamintoll.com/2026/10/06/on-cgroups/).

# Getting Started

1. Compile `sandbox-init.c` as `sandbox-init`.  This is the container anchor, which is analogous to the [pause container](https://github.com/kubernetes/kubernetes/blob/master/build/pause/linux/pause.c) in Kubernetes.
1. Create a virtual machine.  Or, if you're feeling adventurous, run it on your host, but I don't recommend that.
1. Create a mount point at `/mnt/shared` and copy the `cluster` directory into it.
1. Build the cluster.  Here is a shell script to get you started:

    ```bash
    #!/bin/bash
    # shellcheck source=/dev/null

    set -eo pipefail

    LANG=C
    umask 0022

    ERROR="\e[31m[ERROR]\e[0m"

    if [ $EUID -ne 0 ]
    then
        printf "%b This script must be run as root!\n" "$ERROR" 1>&2
        exit 1
    fi

    bash /mnt/shared/cluster/cluster.sh --internet

    bash /mnt/shared/cluster/service.sh --name dns --ip 10.96.64.32 --port 53 --protocol udp
    bash /mnt/shared/cluster/service.sh --name echo --ip 10.96.64.52 --port 9000 --protocol tcp

    bash /mnt/shared/cluster/pod.sh --nodens node0 --pods 2 --service-name dns --process dnsmasq
    bash /mnt/shared/cluster/pod.sh --nodens node1 --pods 1 --service-name dns --process dnsmasq
    bash /mnt/shared/cluster/pod.sh --nodens node1 --pods 2 --service-name echo --process "socat TCP-LISTEN:9000,reuseaddr,fork PTY"
    bash /mnt/shared/cluster/pod.sh --nodens node0 --pods 1 --service-name echo --process "socat TCP-LISTEN:9000,reuseaddr,fork PTY"

    ```

The cluster was designed to use `dnsmasq` for service discovery.  If you want to play with services, you're need to install this on your virtual machine.  If your distro uses `systemd` as the `init` system, it will probably register it and immediately start it.  You don't want this.  Run the following commands to stop it and disable it from running on system start:

```bash
$ sudo systemctl stop dnsmasq.service
$ sudo systemctl disable dnsmasq.service
```

Then, copy the `dnsmasq.conf` configuration in the repository to `/etc` in the virtual machine.

`dnsmasq` should run in a pod rather than system-wide.  To do this, create a pod with a container running `dnsmasq` and tell the pod to use the `dns` service (or whatever you choose to call it) to act as the service load balancer to one or more instances of `dnsmasq`:

```bash
$ sudo bash /mnt/shared/cluster/service.sh --name dns --ip 10.96.64.32 --port 53 --protocol udp
$ sudo bash /mnt/shared/cluster/pod.sh --nodens node1 --pods 1 --service-name dns --process dnsmasq
```

## Node

```bash
$ sudo bash /mnt/shared/cluster/ctl.sh --get nodes
NODE    | NODE IP
node1   | 10.0.0.102
node0   | 10.0.0.101
```

```bash
$ sudo systemctl status node1.slice
● node1.slice - Slice /node1
     Loaded: loaded
    Drop-In: /etc/systemd/system.control/node1.slice.d
             └─50-MemoryMax.conf, 50-TasksMax.conf
     Active: active since Sat 2026-10-03 06:28:02 UTC; 13min ago
 Invocation: 279eeab275eb4800b92b7a4343c68526
      Tasks: 11 (limit: 1000)
     Memory: 1.6M (max: 2G, available: 1.9G, peak: 3M)
        CPU: 67ms
     CGroup: /node1.slice
             ├─node1-pod0.slice
             │ └─node1-pod0.service
             │   ├─1079 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sandbox-init
             │   ├─1080 /mnt/shared/cluster/sandbox-init
             │   └─1089 dnsmasq
             ├─node1-pod1.slice
             │ └─node1-pod1.service
             │   ├─1135 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sandbox-init
             │   ├─1137 /mnt/shared/cluster/sandbox-init
             │   └─1143 socat TCP-LISTEN:9000,reuseaddr,fork PTY
             ├─node1-pod2.slice
             │ └─node1-pod2.service
             │   ├─1167 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sandbox-init
             │   ├─1169 /mnt/shared/cluster/sandbox-init
             │   └─1175 socat TCP-LISTEN:9000,reuseaddr,fork PTY
             └─node1-pod3.slice
               └─node1-pod3.service
                 ├─1511 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sandbox-init
                 └─1513 /mnt/shared/cluster/sandbox-init

Oct 03 06:28:02 dane-brass systemd[1]: Created slice node1.slice - Slice /node1.
```

## Pod

```bash
$ sudo bash /mnt/shared/cluster/pod.sh --nodens node1 --pods 2
Running as unit: node1-pod0.service
Running as unit: node1-pod1.service
```

```bash
$ sudo systemctl status node1-pod0.service
● node1_pod0.service - [systemd-run] /usr/sbin/ip netns exec node1-pod0 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sa>
     Loaded: loaded (/run/systemd/transient/node1-pod0.service; transient)
  Transient: yes
     Active: active (running) since Thu 2026-10-01 17:54:52 UTC; 11min ago
 Invocation: 3ba92e0fd2b34da7ba92a480e49a9cdb
   Main PID: 1142 (unshare)
      Tasks: 2 (limit: 9467)
     Memory: 496K (peak: 1.8M)
        CPU: 52ms
     CGroup: /node1.slice/node1-pod0.slice/node1-pod0.service
             ├─1142 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sandbox-init
             └─1143 /mnt/shared/cluster/sandbox-init

Oct 01 17:54:52 dane-brass systemd[1]: Started node1-pod0.service - [systemd-run] /usr/sbin/ip netns exec node1-pod0 unshare --fork --pid --mount-proc --cgroup>
```

```bash
$ sudo bash /mnt/shared/cluster/pod.sh --nodens node0 --pods 1 --process "tail -f /dev/null" --property MemoryMax=128M --property TasksMax=50
Running as unit: node0-pod0.service
```

```bash
sudo systemctl status node0-pod0.service
● node0-pod0.service - [systemd-run] /usr/sbin/ip netns exec node0-pod0 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sa>
     Loaded: loaded (/run/systemd/transient/node0-pod0.service; transient)
  Transient: yes
     Active: active (running) since Thu 2026-10-01 17:55:23 UTC; 6min ago
 Invocation: 661429007c9d413eb33fb28432416a5b
   Main PID: 1196 (unshare)
      Tasks: 3 (limit: 50)
     Memory: 404K (max: 128M, available: 127.6M, peak: 1.7M)
        CPU: 42ms
     CGroup: /node0.slice/node0-pod0.slice/node0-pod0.service
             ├─1196 unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- /mnt/shared/cluster/sandbox-init
             ├─1197 /mnt/shared/cluster/sandbox-init
             └─1203 tail -f /dev/null

Oct 01 17:55:23 dane-brass systemd[1]: Started node0-pod0.service - [systemd-run] /usr/sbin/ip netns exec node0-pod0 unshare --fork --pid --mount-proc --cgroup>
```

```bash
$ sudo bash /mnt/shared/cluster/ctl.sh --get pods
NODE    | NODE IP      | POD          | POD IP
  node0 |   10.0.0.101 |   node0-pod0 |   172.16.0.102
  node1 |   10.0.0.102 |   node1-pod1 |   172.16.0.101
  node1 |   10.0.0.102 |   node1-pod0 |   172.16.0.100
```

```bash
$ sudo bash /mnt/shared/cluster/ctl.sh --get pids --process dns
NODE    | NODE IP      | POD          | POD IP         | PIDS       | PROCESS
  node1 |   10.0.0.102 |   node1-pod0 |   172.16.0.100 |     1511,6 | dnsmasq
```

```bash
$ sudo bash /mnt/shared/cluster/pod.sh --nodens node1 --pods 1 --process dnsmasq --service-name dns
Running as unit: node1-pod0.service
[INFO] Added server to service `dns` reachable at `10.96.64.32:53` in node net namespace `node1`.
[INFO] Added server to service `dns` reachable at `10.96.64.32:53` in node net namespace `node0`.
```

```bash
$ sudo bash /mnt/shared/cluster/pod.sh --nodens node1 --pods 1 --process "socat TCP-LISTEN:9000,reuseaddr,fork PTY"
Running as unit: node1-pod6.service
$ sudo ip netns exec node1-pod0 socat - TCP:172.16.0.100:9000
hello
hello
world
world
```

## Service

```bash
$ sudo bash /mnt/shared/cluster/service.sh --name dns --ip 10.96.64.32 --port 53 --protocol udp
[INFO] Host file `dns.host` written to /etc/dnsmasq.d.
[INFO] Service file `dns.json` written to /run/cluster/services.d.
[INFO] `dns` service added to `ipvs` in `node1` namespace.
[INFO] `dns` service added to `ipvs` in `node0` namespace.
```

```bash
$ cat /run/cluster/services.d/dns.json
{
    "name": "dns",
    "ip": "10.96.64.32",
    "port": 53,
    "protocol": "udp",
    "scheduler": "rr",
    "servers": []
}
```

```bash
$ sudo ip netns exec node0 ipvsadm -Ln
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
UDP  10.96.64.32:domain rr
```

```bash
$ sudo bash /mnt/shared/cluster/ctl.sh --get services
SERVICE         | IP           | PORT   | PROTOCOL | SERVERS
           echo |  10.96.64.52 |   9000 |      tcp | 172.16.0.103 172.16.0.104 172.16.0.105
            dns |  10.96.64.32 |     53 |      udp | 172.16.0.100 172.16.0.101
```

## Service Discovery

```bash
$ sudo ip netns exec node1 dig @10.96.64.32 +short dns.service.local
10.96.64.32
$ sudo ip netns exec node0-pod0 dig @10.96.64.32 +short dns.service.local
10.96.64.32
$ sudo ip netns exec node1 dig @10.96.64.32 +short benjamintoll.com
167.114.97.28
```

```bash
$ sudo ip netns exec node0 iptables -t nat -L -n -v --line-numbers
Chain PREROUTING (policy ACCEPT 31 packets, 3322 bytes)
num   pkts bytes target     prot opt in     out     source               destination
1       33  3502 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
num   pkts bytes target     prot opt in     out     source               destination

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
num   pkts bytes target     prot opt in     out     source               destination

Chain POSTROUTING (policy ACCEPT 57 packets, 6312 bytes)
num   pkts bytes target     prot opt in     out     source               destination
1        2   180 MASQUERADE  all  --  *      *       172.16.0.0/16        0.0.0.0/0

Chain KUBE-SERVICES (1 references)
num   pkts bytes target     prot opt in     out     source               destination
1        2   180 DNAT       udp  --  *      *       0.0.0.0/0            10.96.64.32          udp dpt:53 to:172.16.0.100:53
```

## `systemd`

```bash
$ sudo systemctl stop node0-pod2.slice
$ sudo systemctl status node0-pod2.slice
○ node0-pod2.slice - Slice /node0/pod2
     Loaded: loaded
    Drop-In: /etc/systemd/system.control/node0-pod2.slice.d
             └─50-MemoryMax.conf
     Active: inactive (dead) since Sat 2026-10-03 05:40:47 UTC; 2min 50s ago
   Duration: 47min 19.112s
 Invocation: e5b4e0aceb644f45925294ddd4273d00
   Mem peak: 1.8M
        CPU: 90ms

Oct 03 04:53:28 dane-brass systemd[1]: Created slice node0-pod2.slice - Slice /node0/pod2.
Oct 03 05:21:04 dane-brass systemd[1]: node0-pod2.slice: Sending signal SIGTERM to process 1236 (unshare) on client request.
Oct 03 05:21:04 dane-brass systemd[1]: node0-pod2.slice: Sending signal SIGTERM to process 1237 (sandbox-init) on client request.
Oct 03 05:21:04 dane-brass systemd[1]: node0-pod2.slice: Sending signal SIGTERM to process 1243 (socat) on client request.
Oct 03 05:40:47 dane-brass systemd[1]: Removed slice node0-pod2.slice - Slice /node0/pod2.
```

## License

[GPLv3](COPYING)

## Author

[Benjamin Toll](https://benjamintoll.com)


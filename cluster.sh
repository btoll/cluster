#!/bin/bash
# shellcheck source=/dev/null

set -eo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"
INFO="\e[34m[INFO]\e[0m"
SUCCESS="\e[32m[SUCCESS]\e[0m"

if [ $EUID -ne 0 ]
then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

trap cleanup ERR

cleanup() {
    local ns

    for ns in $(ip netns list | awk '/node[0-9]+(-pod[0-9]+)?/ {print $1}')
    do
        ip netns delete "$ns"
    done

    ip link delete "host-$BRIDGE" type bridge

    # The sandbox-init process anchors will be re-parented to PID 1 in the host network namespace.
    # If there are `sandbox-init` processes they were created in `pod.sh`.
    for pid in $(pidof sandbox-init)
    do
        kill -SIGKILL "$pid"
    done

    iptables -t nat -D POSTROUTING -o enp2s0 -j MASQUERADE 2> /dev/null

    rm -f /run/cluster.cidrs

    find /sys/fs/cgroup/ -maxdepth 2 -type d -name "node?-pod?.slice" -delete
    find /sys/fs/cgroup/ -type d -name "node?.slice" -delete
    find /run/systemd/transient/ -type f -name "node?_pod?.service" -delete
    systemctl reset-failed node?_pod?.service
    systemctl daemon-reload
}

create_host_bridge() {
    local first_three_octets="${NODE_BRIDGE_IP%.*}"
    local last_octet="${NODE_BRIDGE_IP##*.}"
    local node_netmask="${NODE_NETWORK#*/}"
    local i

    last_octet="$(( last_octet + 100 ))"
    ip link add name "host-$BRIDGE" type bridge
    ip link set "host-$BRIDGE" up

    for ((i=0; i < NODES; i++))
    do
        # Create veth pair.
        ip link add "host-veth$i" type veth peer name "host-ceth$i"

        # Move one end into node ns, add IP address and bring it up.
        ip link set "host-ceth$i" netns "node$i"
        ip -n "node$i" address add "$first_three_octets.$((last_octet + i))/$node_netmask" dev "host-ceth$i"
        ip -n "node$i" link set "host-ceth$i" up

        # Add other end to node bridge and bring it up.
        ip link set dev "host-veth$i" master "host-$BRIDGE"
        ip link set "host-veth$i" up
    done
}

create_iptables_rules() {
    sysctl --write net.ipv4.ip_forward=1 > /dev/null
    iptables --table nat --append POSTROUTING --out-interface enp2s0 --jump MASQUERADE

    for nodens in $(ip netns list | awk '$0 !~ /-/ {print $1}')
    do
        # 1. The Forwarding "On" Switch
        # The node must be allowed to move packets between the pod veth and the vxlan/br0 interfaces.
        ip netns exec "$nodens" sysctl --write net.ipv4.ip_forward=1 > /dev/null
        ip netns exec "$nodens" sysctl --write net.ipv4.ip_forward=1 > /dev/null

        # (Note: If you have multiple pods for one service, you'd add multiple rules here
        # using the -m statistic --mode random --probability module to load balance.)

        #3. The POSTROUTING Chain (The "Return Path")
        #
        #This is the most common point of failure. When the destination pod replies,
        # the packet must be masqueraded so it returns through the node, not directly to the requester.
        #
        # Masquerade all traffic leaving the node that originated from a pod
        ip netns exec "$nodens" iptables --table nat --append POSTROUTING --source 172.16.0.0/16 --jump MASQUERADE

        #4. The FORWARD Chain (The "Permission")
        #
        #Finally, ensure the filter table isn't dropping the packets as they move between interfaces.
        #
        # Allow traffic from pods to services
#        ip netns exec "$nodens" iptables -A FORWARD -s 172.16.0.0/16 -d 10.96.0.0/16 -j ACCEPT
#        # Allow return traffic from services to pods
#        ip netns exec "$nodens" iptables -A FORWARD -s 10.96.0.0/16 -d 172.16.0.0/16 -j ACCEPT
#        # Allow pod-to-pod traffic (for the actual delivery)
#        ip netns exec "$nodens" iptables -A FORWARD -s 172.16.0.0/16 -d 172.16.0.0/16 -j ACCEPT
    done

    #Summary of the Flow now:
    #
    #    Packet arrives in node0 destined for 10.96.64.10.
    #    PREROUTING →→ KUBE-SERVICES →→ DNAT changes destination to 172.16.0.11.
    #    FORWARD chain checks if 172.16.0.11 is allowed →→ ACCEPT.
    #    Packet is routed to the pod.
    #    Pod replies →→ POSTROUTING →→ MASQUERADE changes source to the node's IP.
    #    Packet returns to original requester.

    # If the source and destination are both the same pod, masquerade the source
    # NOTE: I haven't had luck with this.
    # ip netns exec node0 iptables -t nat -A POSTROUTING -s 172.16.0.11 -d 172.16.0.11 -j MASQUERADE
}

create_node() {
    local index="$1"
    local nodens="node$index"

    # Create the node (i.e., the new net namespace which will include
    # the bridge and the veth pair.
    ip netns add "$nodens"

    # Each node gets its own bridge.
    ip -netns "$nodens" link add name "$BRIDGE" type bridge
    ip -netns "$nodens" link set "$BRIDGE" up

    # Bring up loopback (optional).
    ip -netns "$nodens" link set lo up

    systemctl set-property "$nodens.slice" MemoryMax=2G TasksMax=1000
#    systemd-run --no-block --slice="$nodens.slice" \
#        --unit="${nodens}_pod$n.service" \
#        --property="MemoryMax=2G" \
#        ip netns exec "$podns" unshare --fork --pid --mount-proc --uts -- "$INIT_EXEC"
}

enable_cluster_internet_connectivity() {
    local index

    # Adding an address for the host gateway enables nodes to use it as the next hop
    # for traffic leaving the cluster.
    ip address add 10.0.0.254/16 dev host-br0

    # Get only node net namespaces, i.e., node0, node1, etc.
    # What is that `awk` command doing?
    # It is filtering the node namespaces (pod namespaces include hyphens).
    #   $ ip netns list | awk '$0 !~ /-/
    #   node1 (id: 1)
    #   node0 (id: 0)
    #   $ ip netns list | awk '$0 !~ /-/ {print $1}'
    #   node1
    #   node0
    for nodens in $(ip netns list | awk '$0 !~ /-/ {print $1}')
    do
        # Extract the numeric suffix, i.e., node111 -> 111.
        index="${nodens#node}"
        node_gateway="172.16.0.$((index + 1))"

        # Make each node bridge a layer 3 gateway for its pods.
        ip -netns "$nodens" address add "$node_gateway"/16 dev br0

        # Add a route through the host namespace for Internet-bound traffic.
        # It sets the host namespace as the node's default gateway.
        ip -netns "$nodens" route add default via 10.0.0.254 dev host-ceth"$index"
    done
}

setup_vxlan_vteps() {
    local vni=100
    local vtep="vxlan$vni"
    local index
    local local_ip
    local peer_index
    local peer_ip

    for ((index = 0; index < NODES; index++)); do
        local_ip="${NODE_BRIDGE_IP%.*}.$(( ${NODE_BRIDGE_IP##*.} + 100 + index ))"

        ip -netns "node$index" link add "$vtep" type vxlan \
            id "$vni" \
            local "$local_ip" \
            dev "host-ceth$index" \
            dstport 4789

        ip -netns "node$index" link set dev "$vtep" master "$BRIDGE"
        # vxlan adds a 50-byte header.
        ip -netns "node$index" link set "$vtep" mtu 1450
        ip -netns "node$index" link set "$vtep" up

        for ((peer_index = 0; peer_index < NODES; peer_index++)); do
            [ "$peer_index" -eq "$index" ] && continue

            peer_ip="${NODE_BRIDGE_IP%.*}.$(( ${NODE_BRIDGE_IP##*.} + 100 + peer_index ))"

            ip netns exec "node$index" bridge fdb append \
                00:00:00:00:00:00 \
                dev "$vtep" \
                dst "$peer_ip" \
                self permanent
        done
    done
}

status() {
    local n=()
    local p=()
    local a
    local ns
    local v
    local line

    printf "%b net namespaces\n" "$INFO"
    # Remove the network namespace IDS, i.e., `node0 (id: 0)`.
    # This is safe b/c there cannot be a space in a network name.
    for ns in $(ip netns list | awk '{print $1}')
    do
        printf "%b \t\t%s\n" "$INFO" "$ns"
        if [[ "$ns" =~ - ]]
        then
            p+=("$ns")
        else
            n+=("$ns")
        fi
    done

    printf "%b \n" "$INFO"

    printf "%b host\n" "$INFO"
    while read -r line
    do
        printf "%b \t\t%s\n" "$INFO" "$line"
    done < <(ip -br a)

    printf "%b \n" "$INFO"

    for a in n p
    do
        # Create a nameref (`current_array`) that points to the array name stored in `a`.
        declare -n current_array="$a"
        for v in "${current_array[@]}"
        do
            if [ "$VERBOSE" = 1 ]
            then
                if [[ ! ( "$v" =~ - ) ]]
                then
                    printf "%b %s - bridge fdb\n" "$INFO" "$v"
                    while read -r line
                    do
                        printf "%b \t\t%s\n" "$INFO" "$line"
                    done < <(ip netns exec "$v" bridge fdb show br "$BRIDGE")

                    printf "%b \n" "$INFO"

                    printf "%b %s - vxlan fdb\n" "$INFO" "$v"
                    while read -r line
                    do
                        printf "%b \t\t%s\n" "$INFO" "$line"
                    done < <(ip netns exec "$v" bridge fdb show dev vxlan100)

                    printf "%b \n" "$INFO"
                fi
            fi

            printf "%b %s\n" "$INFO" "$v"
            while read -r line
            do
                printf "%b \t\t%s\n" "$INFO" "$line"
            done < <(ip -n "$v" -br a)
            printf "%b \n" "$INFO"
        done
    done
}

usage() {
    printf "Usage: %s OPTIONS

Options:
--destroy       Teardown.
--internet      Flag to enable the cluster (all nodes and pods) access to the Internet.
--node-cidr     The CIDR address for the nodes (defaults to 172.16.0.0/16).
--nodes         Number of nodes in the cluster (defaults to 2).
                Each node gets its own isolated net namespace.
--pod-cidr      The CIDR address for the pods (defaults to 10.0.0.0/16).
--service-cidr  The CIDR address for the nodes (defaults to 10.96.64.0/18).
--status        Prints the network topology.
-v, --verbose   If set, prints bridge and VXLAN fdb entries when --status is set.
-h, --help      Show usage.\n" "$SCRIPTNAME"
    exit "$1"
}

BRIDGE=br0
DESTROY=
INTERNET=
N=100
NODES=2
NODE_CIDR=10.0.0.0/16
NODE_NETWORK=
NODE_BRIDGE_IP=
POD_CIDR=172.16.0.0/16
SCRIPTNAME=$(basename "$0")
SERVICE_CIDR=10.96.64.0/18
STATUS=
VERBOSE=

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --destroy) DESTROY=1 ;;
        --internet) INTERNET=1 ;;
        --node-cidr) shift; NODE_CIDR=$1 ;;
        --nodes) shift; NODES=$1 ;;
        --pod-cidr) shift; POD_CIDR=$1 ;;
#        --service-cidr) shift; SERVICE_CIDR=$1 ;;
        --status) STATUS=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help) usage 0 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

if [ -n "$DESTROY" ]
then
    cleanup
    printf "%b Network topology destroyed.\n" "$SUCCESS"
elif [ -n "$STATUS" ]
then
    status
else
    # ${BASH_SOURCE[0]} contains the path to the current script (unlike `$0`, which can be relative or modified).
    # `dirname` extracts the directory portion.
    # `cd` into that directory and `pwd` resolves it to an absolute path, handling symlinks and relative paths.
    CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$CLUSTER_DIR/parse_cidr.sh"
    read -r NODE_NETWORK NODE_BRIDGE_IP < <(parse_cidr "$NODE_CIDR")

    for ((i=0; i < NODES; i++))
    do
        create_node "$i"
    done

    create_host_bridge
    setup_vxlan_vteps

    if [ "$INTERNET" = 1 ]
    then
        # Add the addresses and routes to the virtual devices.
        enable_cluster_internet_connectivity

        # Configure the firewall.
        create_iptables_rules
    fi

    modprobe br_netfilter

    printf "NODE_CIDR=%s\nPOD_CIDR=%s\nSERVICE_CIDR=%s\nNUM_NODES=%d\nNUM_PODS=0\nN=%d\nP=100\n" "$NODE_CIDR" "$POD_CIDR" "$SERVICE_CIDR" "$NODES" "$N" > /run/cluster.cidrs

    printf "%b Cluster and network topology created.\n" "$SUCCESS"
    printf "%b Run \`$SCRIPTNAME --status [--verbose]\` for details.\n" "$INFO"
fi


#!/bin/bash
# shellcheck source=/dev/null

set -euo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"
INFO="\e[34m[INFO]\e[0m"
#SUCCESS="\e[32m[SUCCESS]\e[0m"

if [ $EUID -ne 0 ]
then
    printf "%b This script must be run as root!\n" "$ERROR" 1>&2
    exit 1
fi

BINS=(
    ipvsadm
    jq
)

for bin in "${BINS[@]}"
do
    if ! command -v "$bin" > /dev/null
    then
        printf "%b \`%s\` not found within PATH.\n" "$ERROR" "$bin"
        exit 1
    fi
done

usage() {
    printf "Usage: %s OPTIONS

Options:
--nodens        The node net namespace in which to place the pod.
--pods          The pods within each node (defaults to 2).
                Each pod gets its own isolated net namespace.
--process       The full executable string.
--property      Sets a cgroup resource limit.  Accepts one per parameter.
--service-name  If fronted by a service, give the name so the IP:PORT will be added to it.
--help, -h      Help.\n" "$(basename "$0")"
    exit "$1"
}

BRIDGE=br0
CLUSTER_CIDRS=/run/cluster.cidrs
NODENS=
PODS=
PROCESS=
PROPERTIES=()
SERVICE_NAME=
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --nodens) shift ; NODENS=$1 ;;
        --pods) shift ; PODS=$1 ;;
        --process) shift ; PROCESS=$1 ;;
        --property) shift ; PROPERTIES+=(--property="$1") ;;
        --service-name) shift ; SERVICE_NAME=$1 ;;
        -h|--help) usage 0 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

if [ ! -f "$CLUSTER_CIDRS" ]
then
    printf "%b \`%s\` does not exist.  Have you run \`%s/cluster.sh\`?\n" "$ERROR" "$CLUSTER_CIDRS" "$SOURCE_DIR"
    exit 1
fi

if [ -z "$NODENS" ]
then
    printf "%b Namespace is required.\n" "$ERROR"
    usage 1
fi

source "$SOURCE_DIR/parse_cidr.sh"
source "$CLUSTER_CIDRS"
NUM_PODS="${NUM_PODS/##}"

# TODO: Check that net namespace exists.

# Given the net namesspace name, we now need to find the sandbox-init process
# that the new process should be re-parented to.
#for pid in /proc/[0-9]*
#do
#    [[ $(readlink "$pid/exe" 2>/dev/null) = */sandbox-init ]] || continue
#    p="${pid##*/}"
#    if [[ $(ip netns identify "$p") = "$NODENS" ]]
#    then
#        CONTAINER_ANCHOR="$p"
#    fi
#done

declare -a IPS

create_pods() {
    read -r POD_NETWORK _ < <(parse_cidr "$POD_CIDR")

    local first_three_octets="${POD_NETWORK%.*}"
    local last_octet="${POD_NETWORK##*.}"
    local pod_netmask="${POD_NETWORK#*/}"
    local podns
    local pairn
    local node_gateway
    local pod_ip
    local procs

    last_octet="$(( last_octet + POD_BASE + NUM_PODS ))"

    local x=0
    # Determine how many pods are in the node net namespace.  This will allow
    # for deleting a pod and then creating a new pod with the same net ns.
    for ns in $(ip netns list)
    do
        [[ "$ns" =~ ${NODENS}- ]] && x=$(( x + 1 ))
    done
    [ "$x" = 0 ] && x=0

    # There is a bug when a pod is deleted, unless it is the newest pod it will
    # fail b/c it will start the new pod creation with the total number of pods.
    # For example, there are six pods (pod0 to pod5).  Pod 1 is deleted.  New pods
    # will then be created starting at pod5 (the total number of existing pods is
    # five), but pod5 already exists (fails with `RTNETLINK answers: File exists`).
    # Not sure this is important enough to fix, b/c it's just a learning tool.
    for ((n=0; n < PODS; n++))
    do
        pairn="$(( x + n ))"
        # Create the veth pair.
        ip -netns "$NODENS" link add "veth$pairn" type veth peer name "ceth$pairn"
        ip -netns "$NODENS" link set "veth$pairn" up

        # Create new "pod" net namespace and move one end of the veth pair into it.
        podns="${NODENS}-pod$pairn"
        ip netns add "$podns"
        ip -netns "$NODENS" link set "ceth$pairn" netns "$podns"

        # Attach the other end to the bridge device.
        ip -netns "$NODENS" link set dev "veth$pairn" master "$BRIDGE"

        # Collect each pod IP in case `--service-name` was specified on the cli.
        pod_ip=$first_three_octets.$(( last_octet + n ))
        IPS+=( "$pod_ip" )
        # Add IP address to the endpoint that was moved into its own net namespace
        # (the "cable" plugged into the bridge does NOT get an IP address).
        ip -netns "$podns" address add "$pod_ip/$pod_netmask" dev "ceth$pairn"
        ip -netns "$podns" link set "ceth$pairn" up

        # Bring up loopback (optional).
        ip -netns "$podns" link set lo up

        # Get the node gateway.
        node_gateway=$(ip -netns "$NODENS" -br address show "$BRIDGE" | awk '{split($3, a, "/"); print a[1]}')
        ip -netns "$podns" route add default via "$node_gateway" dev "ceth$pairn"

        # Somewhat reasonable cgroup memory limit.
        systemctl set-property "${podns}.slice" MemoryMax=1G

        # Add the container anchor.  This is the supervisor that will reap all re-parented children and trap signals.
        SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$SOURCE_DIR/sandbox-init" ] && [ -x "$SOURCE_DIR/sandbox-init" ]
        then
            systemd-run \
                --no-block \
                --slice="${podns}.slice" \
                --unit="${podns}.service" \
                "${PROPERTIES[@]}" \
                ip netns exec "$podns" unshare --fork --pid --mount-proc --cgroup --ipc --uts --time -- "$SOURCE_DIR/sandbox-init"
            # Give the service time to start.
            sleep 1
        fi

        if [ -n "$PROCESS" ]
        then
            procs="/sys/fs/cgroup/${NODENS}.slice/${podns}.slice/${podns}.service/cgroup.procs"
            while read -r pid
            do
                if [ "$(ps -o comm= -p "$pid")" = sandbox-init ]
                then
                    if ! nsenter --target "$pid" --net --pid --mount --cgroup --ipc --uts --time -- sh -c "$PROCESS &"
                    then
                        printf "%b Program could not be re-parented to %s.\n" "$ERROR" "$pid"
                    else
                        # Move the new process into the cgroup hierarchy.
                        for p in $(sudo ip netns pids "$podns")
                        do
                            [ "$(ps -o args= -p "$p")" = "$PROCESS" ] && echo "$p" > "$procs"
                        done
                    fi
                    break
                fi
            done < <(cat "$procs" 2> /dev/null)
        fi
    done

    sed -i "s/^NUM_PODS=[0-9]*$/NUM_PODS=$(( NUM_PODS + PODS ))/" "$CLUSTER_CIDRS"
}

create_pods

SERVICES_DIR=/run/cluster/services.d
if [ -n "$SERVICE_NAME" ] && [ -f "$SERVICES_DIR/$SERVICE_NAME.json" ]
then
    read -r service_ip service_port service_protocol < <(jq -r '[.ip, .port, .protocol] | @tsv' "$SERVICES_DIR/$SERVICE_NAME.json")

    # Add the server(s) to `ipvs` for each node net namespace.
    for node_ns in $(ip netns list | awk '$0 !~ /-/ {print $1}')
    do
        for container_ip in "${IPS[@]}"
        do
            # Add the actual mapping (The "Service" rule).
            ip netns exec "$node_ns" \
                iptables \
                    --table nat \
                    --append KUBE-SERVICES \
                    --destination "$service_ip" \
                    --protocol "$service_protocol" \
                    --dport "$service_port" \
                    --jump DNAT \
                    --to-destination "$container_ip:$service_port"

            # Note that `masquerading` is crucial here and cannot be ommitted.  It does the same job as the KUBE-MARK-MASQ rules in `kube-proxy`.
            ip netns exec "$node_ns" ipvsadm --add-server \
                "--${service_protocol}-service" "$service_ip:$service_port" \
                --real-server "$container_ip:$service_port" --masquerading

            printf "%b Added server to service \`%s\` reachable at \`%s:%s\` in node net namespace \`%s\`.\n" "$INFO" "$SERVICE_NAME" "$service_ip" "$service_port" "$node_ns"
        done
    done

    # Add each service IP to the service definition.
    # Note that `jq` can't update the file in-place, hence the kludge.
    for container_ip in "${IPS[@]}"
    do
        jq --arg ip "$container_ip" '.servers += [$ip]' "$SERVICES_DIR/$SERVICE_NAME.json" \
            > /tmp/t.json && mv /tmp/t.json "$SERVICES_DIR/$SERVICE_NAME.json"
    done
fi


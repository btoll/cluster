#!/bin/bash
# shellcheck source=/dev/null

set -euo pipefail

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

if ! command -v jq > /dev/null
then
    printf "%b \`jq\` not found within PATH.\n" "$ERROR"
    exit 1
fi

delete_node() {
    local nodens="$1"
    local podns
    local i

    if [ -z "$nodens" ]
    then
        printf "%b Must provide a node name.\n" "$ERROR"
        usage 1
    fi

    if [[ "$nodens" =~ "-" ]]
    then
        printf "%b \`%s\` does not appear to be a node.\n" "$ERROR" "$nodens"
        usage 1
    fi

    # Removing the server(s) from the service(s) needs to happen BEFORE the node
    # is removed, because we need access to the IP addresses.
    while read -r podns
    do
        ! [[ "$podns" =~ $nodens ]] && continue

        container_ip="$(awk '/ceth/ {print $3}' <(ip -n "$podns" -br a))"
        container_ip=${container_ip%/*}

        if [ -d "$SERVICES_DIR" ]
        then
            while read -r file
            do
                if grep "$container_ip" "$file" > /dev/null
                then
                    jq --arg ip "$container_ip" '.servers -= [$ip]' "$file" \
                        > /tmp/t.json && mv /tmp/t.json "$file"
                fi
            done < <(find "$SERVICES_DIR" -type f -name "*.json")
        fi
    done < <(awk '$0 ~ /-/ {print $1}' <(ip netns list))

    delete_object "$nodens"

    #TODO:
    # - remove iptable rule
    # - remove ipvsadm server
    i=0
    while read -r podns
    do
        ! [[ "$podns" =~ $nodens ]] && continue
        # `reset-failed` resets the `failed` state.
        systemctl reset-failed "${podns}.service"
        ip netns delete "$podns" # This needs to happen AFTER or else we can't get the IP address!
        i=$(( i + 1 ))
    done < <(awk '$0 ~ /-/ {print $1}' <(ip netns list))
    systemctl daemon-reload

    sed -i "s/^NUM_PODS=[0-9]*$/NUM_PODS=$(( NUM_PODS - i ))/" "$CLUSTER_CIDRS"
    sed -i "s/^NUM_NODES=[0-9]*$/NUM_NODES=$(( NUM_NODES - 1 ))/" "$CLUSTER_CIDRS"
}

delete_object() {
    local ns="$1"

    if ! systemctl status "${ns}.slice" &> /dev/null
    then
        printf "%b Object \`%s\` does not exist.\n" "$ERROR" "$ns"
        exit 1
    fi

    printf "%b Deleting object \`%s\`, this will take a while.\n" "$INFO" "$ns"
    printf "%b \`systemd\` is stopping every process in the cgroup \`%s.slice\` and cleaning up.\n" "$INFO" "$ns"
    systemctl stop "${ns}.slice"
    printf "%b Object \`%s\` was deleted and its service file(s) removed.\n" "$SUCCESS" "$ns"
    ip netns delete "$ns"
}

delete_pod() {
    local podns="$1"
    local container_ip

    if [ -z "$podns" ]
    then
        printf "%b Must provide a pod name.\n" "$ERROR"
        usage 1
    fi

    if ! [[ "$podns" =~ "-" ]]
    then
        printf "%b \`%s\` does not appear to be a pod.\n" "$ERROR" "$podns"
        usage 1
    fi

    container_ip=$(awk '/ceth/ {print $3}' <(ip -n "$podns" -br a))
    container_ip=${container_ip%/*}
    delete_object "$podns"

    # `reset-failed` resets the `failed` state.
    systemctl reset-failed "${podns}.service"
    systemctl daemon-reload

    #TODO:
    # - remove iptable rule
    # - remove ipvsadm server
    # - remove ip address from any service
    sed -i "s/^NUM_PODS=[0-9]*$/NUM_PODS=$(( NUM_PODS - 1 ))/" "$CLUSTER_CIDRS"

    # Remove the server from the service(s).
    if [ -d "$SERVICES_DIR" ]
    then
        while read -r file
        do
            if grep "$container_ip" "$file" > /dev/null
            then
                jq --arg ip "$container_ip" '.servers -= [$ip]' "$file" \
                    > /tmp/t.json && mv /tmp/t.json "$file"
            fi
        done < <(find "$SERVICES_DIR" -type f -name "*.json")
    fi
}

delete_service() {
    true
}

get_pids() {
    local proc="$1"
    local entry

    if [ -z "$proc" ]
    then
        printf "%b Must provide a \`PID\`.\n" "$ERROR"
        usage 1
    fi

    printf "%-7s | %-12s | %-12s | %-14s | %-10s | %-s\n" "NODE" "NODE IP" "POD" "POD IP" "PIDS" "PROCESS"
    while read -r entry
    do
        printf "%7s | %12s | %12s | %14s | %10s | %s\n" \
            "$(jq --raw-output '.nodens' <<< "$entry")" \
            "$(jq --raw-output '.node_ip' <<< "$entry")" \
            "$(jq --raw-output '.podns' <<< "$entry")" \
            "$(jq --raw-output '.pod_ip' <<< "$entry")" \
            "$(jq --raw-output '.pids' <<< "$entry")" \
            "$(jq --raw-output '.proc' <<< "$entry")"

    done < <(get_table_entries "$proc" | jq --compact-output '.[]')
}

get_table_entries() {
    local proc="$1"
    local pid
    local podns
    local pod_ip
    local nodens
    local node_ip
    local pids

    if [ -z "$proc" ]
    then
        printf "%b Must provide a \`PID\`.\n" "$ERROR"
        usage 1
    fi

    declare -a j

    for pid in $(pidof "$proc")
    do
        podns=$(ip netns identify "$pid")
        pod_ip=$(awk '/ceth/ {print $3}' <(ip -n "$podns" -br a))
        nodens="${podns%-*}"
        node_ip=$(awk '/host-ceth/ {print $3}' <(ip -n "$nodens" -br a))
        pids=$(awk '/pid/ {print $2 "," $3}' "/proc/$pid/status")
        j+=(
            "$(jq --compact-output \
                --null-input \
                --arg nodens "$nodens" \
                --arg node_ip "${node_ip%/*}" \
                --arg podns "$podns" \
                --arg pod_ip "${pod_ip%/*}" \
                --arg pids "$pids" \
                --arg proc "$proc" \
                '{$nodens, $node_ip, $podns, $pod_ip, $pids, $proc}')"
        )
    done

    printf "%s\n" "${j[@]}" | jq --slurp "."
}

list_nodes() {
    local nodens
    local ip

    printf "%-7s | %-12s\n" "NODE" "NODE IP"
    while read -r nodens
    do
        ip="$(awk '/host-ceth/ {print $3}' <(ip -n "$nodens" -br a))"
        printf "%-7s | %-12s\n" \
            "$nodens" \
            "${ip%/*}"

    done < <(awk '$0 !~ /-/ {print $1}' <(ip netns list))
}

list_pods() {
    local entry

    printf "%-7s | %-12s | %-12s | %-14s\n" "NODE" "NODE IP" "POD" "POD IP"
    while read -r entry
    do
        printf "%7s | %12s | %12s | %14s\n" \
            "$(jq --raw-output '.nodens' <<< "$entry")" \
            "$(jq --raw-output '.node_ip' <<< "$entry")" \
            "$(jq --raw-output '.podns' <<< "$entry")" \
            "$(jq --raw-output '.pod_ip' <<< "$entry")"

    done < <(get_table_entries sandbox-init | jq --compact-output '.[]')
}

list_services() {
    local entry

    if [ ! -d "$SERVICES_DIR" ]
    then
        printf "%b No services defined in \'%s\'.\n" "$ERROR" "$SERVICES_DIR"
        exit 1
    fi

    printf "%-15s | %-12s | %-6s | %-8s | %s\n" "SERVICE" "IP" "PORT" "PROTOCOL" "SERVERS"
    while read -r entry
    do
        printf "%15s | %12s | %6s | %8s | %s\n" \
            "$(jq --raw-output '.name' <<< "$entry")" \
            "$(jq --raw-output '.ip' <<< "$entry")" \
            "$(jq --raw-output '.port' <<< "$entry")" \
            "$(jq --raw-output '.protocol' <<< "$entry")" \
            "$(jq --raw-output '.servers | join(" ")' <<< "$entry")"
    done < <(find "$SERVICES_DIR" -type f -name "*.json" -exec jq --compact-output . {} +)
}

usage() {
    printf "Usage: %s OPTIONS

Options:
--get
--delete
-p, --process
--help, -h      Help.

Commands:
--get cluster
--get nodes
--get pids
--get pods
--get services
--delete node
--delete pod
--delete service\n" "$(basename "$0")"
    exit "$1"
}

GET=
NAME=
PROCESS=
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --get) shift; GET=$1 ;;
        --delete) shift; DELETE=$1 ;;
        -p|--process) shift; PROCESS=$1 ;;
        --name) shift; NAME=$1 ;;
        -h|--help) usage 0 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

CLUSTER_CIDRS=/run/cluster.cidrs
source "$CLUSTER_CIDRS"
NUM_NODES="${NUM_NODES/##}"
NUM_PODS="${NUM_PODS/##}"
SERVICES_DIR=/run/cluster/services.d/

case $GET in
    cluster) "$SOURCE_DIR/cluster.sh" --status ; exit 0 ;;
    nodes) list_nodes ; exit 0 ;;
    pids) get_pids "$PROCESS" ; exit 0 ;;
    pods) list_pods ; exit 0 ;;
    services) list_services ; exit 0 ;;
#    *) printf "Unknown object %s\n" "$GET"; usage 1 ;;
esac

case $DELETE in
    node) delete_node "$NAME" ; exit 0 ;;
    pod) delete_pod "$NAME" ; exit 0 ;;
    service) delete_service "$NAME" ; exit 0 ;;
    *) printf "Unknown object %s\n" "$GET"; usage 1 ;;
esac


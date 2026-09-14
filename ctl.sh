#!/bin/bash

set -euo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"

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

get_pids() {
    local proc="$1"
    local entry

    if [ -z "$proc" ]
    then
        printf "%b %s\n" "$ERROR" "Must provide a \`PID\`."
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
        printf "%b %s\n" "$ERROR" "Must provide a \`PID\`."
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

usage() {
    printf "Usage: %s OPTIONS

Options:
--get
-p, --process
--help, -h      Help.\n" "$(basename "$0")"
    exit "$1"
}

GET=
PROCESS=
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ "$#" -gt 0 ]
do
    OPT="$1"
    case $OPT in
        --get) shift; GET=$1 ;;
        -p|--process) shift; PROCESS=$1 ;;
        -h|--help) usage 0 ;;
        *) printf "Unknown flag %s\n" "$OPT"; usage 1 ;;
    esac
    shift
done

case $GET in
    cluster) "$SOURCE_DIR/cluster.sh" --status ; exit 0 ;;
    nodes) list_nodes ; exit 0 ;;
    pids) get_pids "$PROCESS" ; exit 0 ;;
    pods) list_pods ; exit 0 ;;
#    *) printf "Unknown object %s\n" "$GET"; usage 1 ;;
esac


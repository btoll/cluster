#!/bin/bash

set -eo pipefail

LANG=C
umask 0022

ERROR="\e[31m[ERROR]\e[0m"

if ! command -v ipcalc > /dev/null
then
    printf "%b \`ipcalc\` not found within PATH.\n" "$ERROR"
    exit 1
fi

parse_cidr() {
    local cidr="$1"
    local network
    local bridge_ip

    while IFS= read -r line
    do
        case "$line" in
            Network:*) network=$(printf "%s" "$line" | awk '{print $2}') ;;
            HostMin:*) bridge_ip=$(printf "%s" "$line" | awk '{print $2}') ;;
        esac
    done <<< "$(ipcalc "$cidr")" # We'll know if the CIDR address is invalid if the vars are empty.

    if [ -z "$network" ]
    then
        printf "%b \`%s\` is an invalid CIDR address.\n" "$ERROR" "$cidr"
        usage 1
    fi

    echo "$network $bridge_ip"
}


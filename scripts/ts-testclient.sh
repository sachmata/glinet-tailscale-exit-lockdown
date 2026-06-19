#!/bin/sh
# /tmp/ts-testclient.sh -- synthetic LAN client in a netns, for testing forwarding/egress.
# Usage: ts-testclient.sh up | down | run <cmd...>
NS=tsclient
VETH_H=tsc_h
VETH_N=tsc_n
CIP=192.168.8.250
PREFIX=24
GW=192.168.8.1
LAN_BR=br-lan

down() {
    ip netns del $NS 2>/dev/null
    ip link del $VETH_H 2>/dev/null
    rm -rf /etc/netns/$NS
}
up() {
    down
    ip netns add $NS
    mkdir -p /etc/netns/$NS
    echo "nameserver $GW" > /etc/netns/$NS/resolv.conf
    ip link add $VETH_H type veth peer name $VETH_N
    ip link set $VETH_H master $LAN_BR
    ip link set $VETH_H up
    ip link set $VETH_N netns $NS
    ip netns exec $NS ip link set lo up
    ip netns exec $NS ip addr add $CIP/$PREFIX dev $VETH_N
    ip netns exec $NS ip link set $VETH_N up
    ip netns exec $NS ip route add default via $GW
    echo "tsclient up ($CIP via $GW)"
}
case "$1" in
    up)  up ;;
    down) down; echo "tsclient down" ;;
    run) shift; ip netns exec $NS "$@" ;;
    *) echo "usage: $0 up|down|run <cmd...>"; exit 1 ;;
esac

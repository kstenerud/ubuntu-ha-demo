#!/bin/bash

set -eu

UBUNTU_DISTRO=bionic


##########
# Common #
##########

declare -A GUEST_BRIDGES
GUEST_BRIDGES[lxd]=lxdbr0
GUEST_BRIDGES[multipass]=mpqemubr0
GUEST_BRIDGES[uvtools]=virbr0

declare -A GUEST_TYPES

get_bridge_network_address()
{
    guest_type=$1
    bridge=${GUEST_BRIDGES[$guest_type]}
    ip addr show dev $bridge | grep "inet " | sed 's/.*inet \([^/]*\/[0-9]*\).*/\1/g'
}

set_guest_type()
{
    guest_name="$1"
    guest_type="$2"
    GUEST_TYPES[$guest_name]="$guest_type"
}

create_guest()
{
    guest_name="$1"
    guest_type="$2"
    remote="$3"
    image="$4"

    set_guest_type "$guest_name" "$guest_type"
    delete_guest "$guest_name"

    echo "HOST:"
    echo "\`\`\`shell"

    case "$guest_type" in
        "lxd")
            image_arg=$image
            if [ "$remote" == "daily" ]; then
                image_arg="ubuntu-daily:$image"
            fi
            echo "$ lxc launch $image_arg $guest_name"
            lxc launch $image_arg $guest_name
            ;;
        "multipass")
            echo "$ multipass launch $remote:$image --name $guest_name"
            multipass launch $remote:$image --name $guest_name
            ;;
        "uvtools")
            remote_arg=
            if [ "$remote" == "daily" ]; then
                remote_arg="label=daily"
            fi
            echo "$ uvt-kvm create $guest_name arch=amd64 $remote_arg release=$image"
            uvt-kvm create $guest_name arch=amd64 $remote_arg release=$image
            uvt-kvm wait $guest_name
            ;;
        *)
            echo "$guest_name has unknown guest type $guest_type"
            return 1
            ;;
    esac

    wait_for_guest_network "$guest_name"
    echo "\`\`\`"
}

delete_guest()
{
    guest_name="$1"
    guest_type="${GUEST_TYPES[$guest_name]}"
    case "$guest_type" in
        "lxd")
            lxc delete -f $guest_name >/dev/null 2>&1 || true
            ;;
        "multipass")
            multipass delete -p $guest_name >/dev/null 2>&1 || true
            ;;
        "uvtools")
            uvt-kvm destroy $guest_name >/dev/null 2>&1 || true
            ;;
        *)
            echo "$guest_name has unknown guest type $guest_type"
            return 1
            ;;
    esac
}

exec_guest()
{
    guest_name="$1"
    guest_type="${GUEST_TYPES[$guest_name]}"
    shift
    case "$guest_type" in
        "lxd")
            lxc exec $guest_name -- $@
            ;;
        "multipass")
            multipass exec $guest_name -- $@
            ;;
        "uvtools")
            uvt-kvm ssh $guest_name -- $@
            ;;
        *)
            echo "$guest_name has unknown guest type $guest_type"
            return 1
            ;;
    esac
}

exec_guest_quoted()
{
    guest_name="$1"
    guest_type="${GUEST_TYPES[$guest_name]}"
    shift
    command="bash -c \"$@\""
    case "$guest_type" in
        "lxd")
            lxc exec $guest_name -- "$@"
            ;;
        "multipass")
            multipass exec $guest_name -- $command
            ;;
        "uvtools")
            uvt-kvm ssh $guest_name -- $command
            ;;
        *)
            echo "$guest_name has unknown guest type $guest_type"
            return 1
            ;;
    esac
}

urlref()
{
    echo
    echo
    echo "### [$@]($@)"
}

guide()
{
    echo
    echo
    echo "#### $@"
    echo
}

run_cmd()
{
    guest_name="$1"
    shift
    echo "GUEST $guest_name:"
    echo "\`\`\`shell"
    echo "$ $@"
    exec_guest "$guest_name" $@
    echo "\`\`\`"
}

run_cmd_quoted()
{
    guest_name="$1"
    shift
    echo "GUEST $guest_name:"
    echo "\`\`\`shell"
    echo "$ $@"
    exec_guest_quoted "$guest_name" $@
    echo "\`\`\`"
}

is_guest_network_up()
{
    guest_name="$1"
    exec_guest "$guest_name" grep $'\t0003\t' /proc/net/route >/dev/null
}

wait_for_guest_network()
{
    guest_name="$1"
    until is_guest_network_up "$guest_name";
    do
        echo "Waiting for network"
        sleep 1
    done
}

get_guest_ip_address()
{
    guest_name=$1
    exec_guest "$guest_name" ip addr | grep 'inet ' | grep global | sed 's/.*inet \([^/]*\).*/\1/g' |head -1
}


########################
# Application Specific #
########################

create_ha_node()
{
    guest_name="$1"
    guest_type="$2"
    password="$3"

    create_guest "$guest_name" $guest_type daily $UBUNTU_DISTRO
    run_cmd "$guest_name" bash -c "echo hacluster:$password | sudo chpasswd"
    run_cmd "$guest_name" sudo apt update
    # run_cmd "$guest_name" sudo apt dist-upgrade -y
    # add_host_entry "$guest_name" apt-cache
    # echo "Acquire::http { Proxy \"http://apt-cache:3142\"; }" | run_cmd "$guest_name" sudo tee /etc/apt/apt.conf.d/00-apt-proxy
    run_cmd "$guest_name" sudo apt install -y pacemaker pcs corosync fence-agents
    # run_cmd_quoted "$guest_name" "echo \"hacluster\nhacluster\" | sudo passwd hacluster"
}


add_host_entry()
{
    guest_to_modify="$1"
    guest_to_add="$2"
    ip_address=$(get_guest_ip_address "$guest_to_add")
    run_cmd_quoted "$guest_to_modify" "echo $ip_address $guest_to_add $guest_to_add | sudo tee -a /etc/hosts"
}

print_usage()
{
    echo "Usage: $(basename $0) <cluster address>"
}


#################
# Configuration #
#################

NODE1=ha-node1
NODE2=ha-node2
HACLUSTER_PASSWORD=hacluster
# NODE_TYPE=uvtools
NODE_TYPE=multipass
# NODE_TYPE=lxd

if [ $# -ne 1 ]; then
    echo "Please provide an unused ip address on the bridge used by $NODE_TYPE ($(get_bridge_network_address $NODE_TYPE))"
    print_usage
    exit 1
fi

IP_ADDRESS=$1


##########
# Script #
##########

echo
echo "HA Cluster Demonstration"
echo "------------------------"


set_guest_type apt-cache lxd

# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/index.html
guide "Create two nodes"
create_ha_node $NODE1 $NODE_TYPE $HACLUSTER_PASSWORD
create_ha_node $NODE2 $NODE_TYPE $HACLUSTER_PASSWORD

# guide "Add reciprocal host entries"
# add_host_entry $NODE1 $NODE2
# add_host_entry $NODE2 $NODE1


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_configure_corosync.html
guide "On one of the nodes, use pcs cluster auth to authenticate as the hacluster user"
run_cmd $NODE1 sudo pcs cluster auth $NODE1 $NODE2 -u hacluster -p $HACLUSTER_PASSWORD --force

guide "Use pcs cluster setup on the same node to generate and synchronize the corosync configuration"
run_cmd $NODE1 sudo pcs cluster setup --name my_cluster $NODE1 $NODE2 --start --enable --force

echo DONE
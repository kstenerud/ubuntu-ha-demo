#!/bin/bash

set -eu


##########
# Common #
##########

declare -A GUEST_TYPES

get_bridge_network_address()
{
    guest_type=$1
    bridge=INVALID
    case "$guest_type" in
        "lxd")
            bridge=lxdbr0
            ;;
        "multipass")
            bridge=mpqemubr0
            ;;
        *)
            echo "$guest_type: Invalid guest type"
            return 1
            ;;
    esac

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
            echo "$ lxc launch $remote:$image $guest_name"
            lxc launch $remote:$image $guest_name
            ;;
        "multipass")
            echo "$ multipass launch $remote:$image --name $guest_name"
            multipass launch $remote:$image --name $guest_name
            ;;
        *)
            echo "$guest_name has unknown guest type $guest_type"
            return 1
            ;;
    esac

    wait_for_guest_network "$guest_name"
    echo "\`\`\`"
    run_cmd "$guest_name" sudo apt update
    run_cmd "$guest_name" sudo apt dist-upgrade -y
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
    case "$guest_type" in
        "lxd")
            lxc exec $guest_name -- bash -c "$@"
            ;;
        "multipass")
            multipass exec $guest_name -- bash -c "$@"
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
    exec_guest_quoted "$guest_name" "$@"
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

    if [ "$guest_type" == "lxd" ]; then
        create_guest "$guest_name" lxd ubuntu-daily cosmic
    else
        create_guest "$guest_name" multipass daily cosmic
    fi
    run_cmd "$guest_name" sudo apt install -y pacemaker pcs corosync fence-agents
    run_cmd_quoted "$guest_name" "echo hacluster:$password | sudo chpasswd"
}


add_host_entry()
{
    guest_to_modify="$1"
    guest_to_add="$2"
    ip_address=$(get_guest_ip_address "$guest_to_add")
    run_cmd_quoted "$guest_to_modify" "echo \"$ip_address $guest_to_add $guest_to_add\" | sudo tee -a /etc/hosts"
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
# NODE_TYPE=multipass
NODE_TYPE=lxd

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


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/index.html
guide "Create two nodes"
create_ha_node $NODE1 $NODE_TYPE $HACLUSTER_PASSWORD
create_ha_node $NODE2 $NODE_TYPE $HACLUSTER_PASSWORD

guide "Add reciprocal host entries"
add_host_entry $NODE1 $NODE2
add_host_entry $NODE2 $NODE1


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_configure_corosync.html
guide "On one of the nodes, use pcs cluster auth to authenticate as the hacluster user"
run_cmd $NODE1 sudo pcs cluster auth $NODE1 $NODE2 -u hacluster -p $HACLUSTER_PASSWORD --force

guide "Use pcs cluster setup on the same node to generate and synchronize the corosync configuration"
run_cmd $NODE1 sudo pcs cluster setup --name my_cluster $NODE1 $NODE2 --start --enable --force


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/ch04.html
guide "Start the cluster"
run_cmd $NODE1 sudo pcs cluster start --all


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_verify_corosync_installation.html
guide "Use corosync-cfgtool to check whether cluster communication is happy"
run_cmd $NODE1 sudo corosync-cfgtool -s

guide "Check the membership and quorum APIs"
run_cmd_quoted $NODE1 "sudo corosync-cmapctl | grep members"
run_cmd $NODE1 sudo pcs status corosync


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_verify_pacemaker_installation.html
guide "Check that the necessary processes are running"
run_cmd_quoted $NODE1 "sudo ps axf | grep corosync"
run_cmd_quoted $NODE1 "sudo ps axf | grep pacemaker"

guide "Check the pcs status output"
run_cmd $NODE1 sudo pcs status

guide "Ensure there are no start-up errors from corosync or pacemaker (aside from messages relating to not having STONITH configured, which are OK at this point)"
run_cmd_quoted $NODE1 "sudo journalctl -b | grep -i error"


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/ch05.html
guide "Check the xml"
run_cmd $NODE1 sudo pcs cluster cib

guide "Check the validity of the configuration"
run_cmd $NODE1 sudo crm_verify -L -V || true

guide "To disable STONITH, set the stonith-enabled cluster option to false. Don't do this in production."
run_cmd $NODE1 sudo pcs property set stonith-enabled=false
run_cmd $NODE1 sudo crm_verify -L -V


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_add_a_resource.html
guide "Create an IP address resource that can be brought up on any node"
run_cmd $NODE1 sudo pcs resource create ClusterIP ocf:heartbeat:IPaddr2 ip=$IP_ADDRESS cidr_netmask=32 op monitor interval=30s

guide "Obtain a list of the available resource standards (the ocf part of ocf:heartbeat:IPaddr2)"
run_cmd $NODE1 sudo pcs resource standards

guide "Obtain a list of the available OCF resource providers (the heartbeat part of ocf:heartbeat:IPaddr2)"
run_cmd $NODE1 sudo pcs resource providers

guide "See all the resource agents available for a specific OCF provider (the IPaddr2 part of ocf:heartbeat:IPaddr2)"
run_cmd $NODE1 sudo pcs resource agents ocf:heartbeat

guide "Verify that the IP resource has been added, and display the cluster’s status to see that it is now active"
sleep 2
run_cmd $NODE1 sudo pcs status


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_perform_a_failover.html
guide "Perform a failover"
run_cmd $NODE1 sudo pcs cluster stop $NODE1

guide "Verify that pacemaker and corosync are no longer running"
run_cmd $NODE1 sudo pcs status || true

guide "Check cluster status on the other node"
run_cmd $NODE2 sudo pcs status

guide "Now, simulate node recovery by restarting the cluster stack on node 1"
run_cmd $NODE1 sudo pcs cluster start $NODE1
sleep 2
run_cmd $NODE1 sudo pcs status


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_prevent_resources_from_moving_after_recovery.html
guide "Prevent resources from moving after recovery"
run_cmd $NODE1 sudo pcs resource defaults resource-stickiness=100
run_cmd $NODE1 sudo pcs resource defaults


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/ch06.html
guide "Install Apache"
run_cmd $NODE1 sudo apt install -y apache2
run_cmd $NODE2 sudo apt install -y apache2

guide "Disable Apache so it doesn't start automatically"
run_cmd $NODE1 sudo systemctl disable apache2
run_cmd $NODE1 sudo systemctl stop apache2
run_cmd $NODE2 sudo systemctl disable apache2
run_cmd $NODE2 sudo systemctl stop apache2


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_create_website_documents.html
guide "Create an html document"
run_cmd_quoted $NODE1 "sudo cat <<END >/var/www/html/index.html
 <html>
 <body>My Test Site - \$(hostname)</body>
 </html>
END"
run_cmd_quoted $NODE2 "sudo cat <<END >/var/www/html/index.html
 <html>
 <body>My Test Site - \$(hostname)</body>
 </html>
END"


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_enable_the_apache_status_url.html
guide "Enable the Apache status URL"
run_cmd_quoted $NODE1 "sudo cat <<END >/etc/apache2/conf-available/status.conf
 <Location /server-status>
    SetHandler server-status
    Require local
 </Location>
END"
run_cmd $NODE1 sudo ln -rs /etc/apache2/conf-available/status.conf /etc/apache2/conf-enabled/status.conf
run_cmd_quoted $NODE2 "sudo cat <<END >/etc/apache2/conf-available/status.conf
 <Location /server-status>
    SetHandler server-status
    Require local
 </Location>
END"
run_cmd $NODE2 sudo ln -rs /etc/apache2/conf-available/status.conf /etc/apache2/conf-enabled/status.conf


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_configure_the_cluster.html
guide "Add Apache to the cluster"
run_cmd $NODE1 sudo pcs resource create WebSite ocf:heartbeat:apache  \
                   configfile=/etc/apache2/apache2.conf \
                   statusurl="http://localhost/server-status" \
                   op monitor interval=1min
run_cmd $NODE1 sudo pcs resource op defaults timeout=240s

guide "Verify that Apache is running"
sleep 2
run_cmd $NODE1 sudo pcs status
run_cmd $NODE1 sudo wget -O - http://localhost/server-status


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_ensure_resources_run_on_the_same_host.html
guide "Ensure related resources run on the same host"
run_cmd $NODE1 sudo pcs constraint colocation add WebSite with ClusterIP INFINITY
run_cmd $NODE1 sudo pcs constraint
run_cmd $NODE1 sudo pcs status


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_ensure_resources_start_and_stop_in_order.html
guide "Ensure resources start and stop in the right order"
run_cmd $NODE1 sudo pcs constraint order ClusterIP then WebSite
run_cmd $NODE1 sudo pcs constraint


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_prefer_one_node_over_another.html
guide "Prefer one node over another"
run_cmd $NODE1 sudo pcs constraint location WebSite prefers $NODE1=50
run_cmd $NODE1 sudo pcs constraint
sleep 2
run_cmd $NODE1 sudo pcs status

guide "Figure out why WebSite is still running on $NODE2"
run_cmd $NODE1 sudo crm_simulate -sL


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/_move_resources_manually.html
guide "Move resources manually"
run_cmd $NODE1 sudo pcs resource move WebSite $NODE1
run_cmd $NODE1 sudo pcs constraint
sleep 2
run_cmd $NODE1 sudo pcs status

guide "Remove temporary constraints"
run_cmd $NODE1 sudo pcs resource clear WebSite
run_cmd $NODE1 sudo pcs constraint
sleep 2
run_cmd $NODE1 sudo pcs status


# ----------------------------------------------------------------------------
urlref http://clusterlabs.org/pacemaker/doc/en-US/Pacemaker/2.0/html/Clusters_from_Scratch/ch07.html
guide "Install DRDB"
run_cmd_quoted $NODE1 "echo postfix postfix/mailname string $NODE1.local | sudo debconf-set-selections"
run_cmd_quoted $NODE1 "echo postfix postfix/main_mailer_type string 'Local Only' | sudo debconf-set-selections"
run_cmd $NODE1 sudo apt install -y drbd-utils
run_cmd_quoted $NODE2 "echo postfix postfix/mailname string $NODE2.local | sudo debconf-set-selections"
run_cmd_quoted $NODE2 "echo postfix postfix/main_mailer_type string 'Local Only' | sudo debconf-set-selections"
run_cmd $NODE2 sudo apt install -y drbd-utils

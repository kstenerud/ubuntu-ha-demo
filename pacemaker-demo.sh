#!/bin/bash


# sudo snap set multipass driver=LIBVIRT
# sudo snap set multipass driver=QEMU


# #cloud-config
#
# bootcmd:
#   # https://github.com/CanonicalLtd/multipass/issues/666
#   - sudo ln -fs /run/systemd/resolve/resolv.conf /etc/resolv.conf
#   # Point the local hostname to its actual external address
#   - sed -i "s/127.0.1.1 {{fqdn}} {{hostname}}/$(ip addr | awk '/global/ {print $2}' | sed 's/\([^\/]*\)\/.*/\1/g') {{fqdn}} {{hostname}}/g" /etc/cloud/templates/hosts.debian.tmpl
#
# packages:
#   - pacemaker
#   - pcs
#   - corosync
#   - fence-agents
#   - nginx

# -------------------------------------

set -eu


echo
echo "### Rebuilding pm-node1 and pm-node2"

multipass delete -p pm-node1 || true
multipass delete -p pm-node2 || true

multipass launch daily:bionic --cloud-init ./pacemaker-cloud-config.yaml --name pm-node1
multipass launch daily:bionic --cloud-init ./pacemaker-cloud-config.yaml --name pm-node2
multipass exec pm-node1 -- bash -c "echo hacluster:hacluster | sudo chpasswd"
multipass exec pm-node2 -- bash -c "echo hacluster:hacluster | sudo chpasswd"

ip_node1=$(multipass exec pm-node1 -- ip addr | grep 'inet ' | grep global | head -1 | sed 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/g')
ip_node2=$(multipass exec pm-node2 -- ip addr | grep 'inet ' | grep global | head -1 | sed 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/g')
ip_dot2=$(multipass exec pm-node1 -- ip addr | grep 'inet ' | grep global | head -1 | sed 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\)\..*/\1.2/g')


echo
echo "### Generate example home pages for nginx"

multipass exec pm-node1 -- sudo bash -c "echo '<html><h1>Primary</h1></html>' >/var/www/html/index.html"
multipass exec pm-node2 -- sudo bash -c "echo '<html><h1>Secondary</h1></html>' >/var/www/html/index.html"


echo
echo "### Set up and start cluster"

multipass exec pm-node1 -- sudo pcs cluster auth pm-node1 pm-node2 -u hacluster -p hacluster
multipass exec pm-node1 -- sudo pcs cluster enable
multipass exec pm-node1 -- sudo pcs cluster setup --name my_cluster pm-node1 pm-node2 --force
multipass exec pm-node1 -- sudo pcs cluster start --all


echo
echo "### Check status"

multipass exec pm-node1 -- sudo corosync-cfgtool -s
multipass exec pm-node1 -- sudo corosync-cmapctl | grep members
multipass exec pm-node1 -- sudo pcs status corosync
multipass exec pm-node1 -- sudo ps axf | grep corosync
multipass exec pm-node1 -- sudo ps axf | grep pacemaker
multipass exec pm-node1 -- sudo pcs status


echo
echo "### Examine resulting xml"

multipass exec pm-node1 -- sudo pcs cluster cib

#multipass exec pm-node1 -- sudo journalctl -b | grep -i error
# There will be errors relating to STONITH


echo
echo "### Verify installation (will fail due to STONITH)"

multipass exec pm-node1 -- sudo crm_verify -L -V || true


echo
echo "### Disable STONITH for demo purposes (don't do this in production)"

multipass exec pm-node1 -- sudo pcs property set stonith-enabled=false
multipass exec pm-node1 -- sudo crm_verify -L -V


echo
echo "### Create virtual IP address (ClusterIP) $ip_dot2"
multipass exec pm-node1 -- sudo pcs resource create ClusterIP ocf:heartbeat:IPaddr2 ip=$ip_dot2 cidr_netmask=32 op monitor interval=30s

echo "### Obtain a list of the available resource standards (the ocf part of ocf:heartbeat:IPaddr2)"
multipass exec pm-node1 -- sudo pcs resource standards

echo "### Obtain a list of the available OCF resource providers (the heartbeat part of ocf:heartbeat:IPaddr2)"
multipass exec pm-node1 -- sudo pcs resource providers

echo "### See all the resource agents available for a specific OCF provider (the IPaddr2 part of ocf:heartbeat:IPaddr2)"
multipass exec pm-node1 -- sudo pcs resource agents ocf:heartbeat

echo "### Verify that the IP resource has been added, and is active (Started)"
while ! multipass exec pm-node1 -- sudo pcs status | grep Started; do
	sleep 1
done


echo
echo "### Add Nginx (WebSite) to the cluster"
multipass exec pm-node1 -- sudo pcs resource create WebSite ocf:heartbeat:nginx \
                                configfile=/etc/nginx/nginx.conf \
                                op monitor interval=5s
multipass exec pm-node1 -- sudo pcs resource op defaults timeout=240s


# echo
# echo "### Check nginx status"
# multipass exec pm-node1 -- curl http://localhost/nginx_status


echo
echo "### Shut down Nginx and make sure it doesn't start automatically"
multipass exec pm-node1 -- sudo systemctl disable nginx
multipass exec pm-node1 -- sudo systemctl stop nginx
multipass exec pm-node2 -- sudo systemctl disable nginx
multipass exec pm-node2 -- sudo systemctl stop nginx


echo
echo "### Ensure related resources run on the same host"
multipass exec pm-node1 -- sudo pcs constraint colocation add WebSite with ClusterIP INFINITY
multipass exec pm-node1 -- sudo pcs constraint
multipass exec pm-node1 -- sudo pcs status


echo
echo "### Ensure resources start and stop in the right order"
multipass exec pm-node1 -- sudo pcs constraint order ClusterIP then WebSite
multipass exec pm-node1 -- sudo pcs constraint


echo
echo "### Make WebSite prefer node 1"
multipass exec pm-node1 -- sudo pcs constraint location WebSite prefers pm-node1=50
multipass exec pm-node1 -- sudo pcs constraint
sleep 2
multipass exec pm-node1 -- sudo pcs status


# echo
# echo "### Testing failover. Original HTTP fetch. Should be Primary:"
# curl $ip_dot2

# echo "### Stop pm-node1, then HTTP fetch. Should be Secondary:"
# multipass exec pm-node1 -- sudo pcs cluster stop pm-node1
# curl $ip_dot2

# echo "### Restart pm-node1, then HTTP fetch. Should be Primary:"
# multipass exec pm-node1 -- sudo pcs cluster start pm-node1
# sleep 2
# curl $ip_dot2


echo "### End of demo. Note: pm-node1 and pm-node2 are still running."

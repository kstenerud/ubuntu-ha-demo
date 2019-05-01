#!/bin/bash

# #cloud-config
#
# bootcmd:
#   # https://github.com/CanonicalLtd/multipass/issues/666
#   - sudo ln -fs /run/systemd/resolve/resolv.conf /etc/resolv.conf
#
# packages:
#   - nginx
#   - keepalived

# ---------------------------------------------------------

set -eu


echo "### Rebuilding ka-node1 and ka-node2"

multipass delete -p ka-node1 || true
multipass delete -p ka-node2 || true

multipass launch daily:cosmic --cloud-init ./keepalived-cloud-config.yaml --name ka-node1
multipass launch daily:cosmic --cloud-init ./keepalived-cloud-config.yaml --name ka-node2

ip_node1=$(multipass exec ka-node1 -- ip addr | grep 'inet ' | grep global | head -1 | sed 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/g')
ip_node2=$(multipass exec ka-node2 -- ip addr | grep 'inet ' | grep global | head -1 | sed 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/g')
ip_dot3=$(multipass exec ka-node1 -- ip addr | grep 'inet ' | grep global | head -1 | sed 's/.*inet \([0-9]*\.[0-9]*\.[0-9]*\)\..*/\1.3/g')


echo
echo "### Generate example home pages for nginx"

multipass exec ka-node1 -- sudo bash -c "echo '<html><h1>Primary</h1></html>' >/var/www/html/index.html"
multipass exec ka-node2 -- sudo bash -c "echo '<html><h1>Secondary</h1></html>' >/var/www/html/index.html"


echo
echo "### Configure keepalived"

multipass exec ka-node1 -- sudo bash -c "cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script chk_nginx {
    script \"/usr/sbin/service nginx status\"
    interval 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    virtual_router_id 33
    state MASTER
    priority 200
    interface ens3
    advert_int 1
    accept
    unicast_src_ip $ip_node1
    unicast_peer {
    	$ip_node2
    }

    authentication {
        auth_type PASS
        auth_pass mypass
    }

    virtual_ipaddress {
        $ip_dot3
    }

    track_script {
        chk_nginx
    }
}
EOF"

# Differences: priority, unicast_src_ip, unicast_peer
multipass exec ka-node2 -- sudo bash -c "cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script chk_nginx {
    script \"/usr/sbin/service nginx status\"
    interval 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    virtual_router_id 33
    state MASTER
    priority 100
    interface ens3
    advert_int 1
    accept
    unicast_src_ip $ip_node2
    unicast_peer {
    	$ip_node1
    }

    authentication {
        auth_type PASS
        auth_pass mypass
    }

    virtual_ipaddress {
        $ip_dot3
    }

    track_script {
        chk_nginx
    }
}
EOF"


echo
echo "### Restart keepalived"

multipass exec ka-node1 -- sudo service keepalived start
multipass exec ka-node2 -- sudo service keepalived start


echo
echo "### Testing failover. Original HTTP fetch. Should be Primary:"
curl $ip_dot3

echo "### Stop ka-node1, then HTTP fetch. Should be Secondary:"
multipass stop ka-node1
curl $ip_dot3

echo "### Restart ka-node1, then HTTP fetch. Should be Primary:"
multipass start ka-node1
sleep 2
curl $ip_dot3


echo "### End of demo. Note: ka-node1 and ka-node2 are still running."

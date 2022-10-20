#!/usr/bin/env bash

STATE='MASTER'
INTERFACE='enp0s6'
ROUTER_ID=51
PRIORITY=100
AUTH_PASS=1234
APISERVER_VIP='192.168.64.200'
APISERVER_DEST_PORT=16443

APISERVER_SRC_PORT=6443
HOST1_ID="cluster.local.control-plane.1"
HOST1_ADDRESS="192.168.64.104"
HOST2_ID="cluster.local.control-plane.2"
HOST2_ADDRESS="192.168.64.105"

sudo mkdir -p /etc/keepalived /etc/haproxy

cat <<EOF | sudo tee /etc/keepalived/keepalived.conf > /dev/null
#---------------------------------------------------------------------
# Configuration File for keepalived
#---------------------------------------------------------------------
global_defs {
    # String identifying the machine. It doesn't have to be hostname (default: local host name)
    router_id LVS_DEVEL
}

#---------------------------------------------------------------------
# Adds a script to be executed periodically. Its exit code will be recorded for all VRRP instances and sync groups which are monitoring it
#---------------------------------------------------------------------
vrrp_script kube-api-lb-script {

    #---------------------------------------------------------------------
    # path of the script to execute  
    #---------------------------------------------------------------------
    script "/etc/keepalived/check_apiserver.sh"

    #---------------------------------------------------------------------
    # seconds between script invocations, (default: 1 second)
    #---------------------------------------------------------------------
    interval 3

    #---------------------------------------------------------------------
    # adjust priority by this weight, (default: 0) For description of reverse, see track_script. 'weight 0 reverse' will cause the vrrp instance to be down when the script is up, and vice versa.
    #---------------------------------------------------------------------
    weight -2

    #---------------------------------------------------------------------
    # required number of successes for OK transition
    #---------------------------------------------------------------------
    rise 2

    #---------------------------------------------------------------------
    # required number of successes for KO transition
    #---------------------------------------------------------------------
    fall 10
}

#---------------------------------------------------------------------
# A VRRP Instance is the VRRP protocol key feature. It defines and configures VRRP behaviour to run on a specific interface.  Each  VRRP  Instance is related to a unique interface.
#---------------------------------------------------------------------
vrrp_instance VI_1 {

    #---------------------------------------------------------------------
    #  Initial state is MASTER|BACKUP. If the priority is 255, then the instance will transition immediately to MASTER if state MASTER is specified otherwise the instance will wait between 3 and 4 advert intervals before it can transition, depending on the priority.
    #---------------------------------------------------------------------
    state ${STATE}

    #---------------------------------------------------------------------
    # interface for inside_network, bound by vrrp.
    # Note: if using unicasting, the interface can be omitted as long as the unicast addresses are not IPv6 link local addresses (this is necessary, for example, if using asymmetric routing).
    # If the interface is omitted, then all VIPs and eVIPs should specify the interface they are to be configured on, otherwise they will be added to the default interface.
    #---------------------------------------------------------------------
    interface ${INTERFACE}

    #---------------------------------------------------------------------
    # arbitrary unique number from 1 to 255 used to differentiate multiple instances of vrrpd running on the same network interface and address family and multicast/unicast (and hence same socket).
    # Note: using the same virtual_router_id with the same address family on different interfaces has been known to cause problems with some network switches; if you are experiencing problems with using the same virtual_router_id on different interfaces, but the problems are resolved by not duplicating virtual_router_ids, your network switches are probably not functioning correctly.
    # Whilst in general it is important not to duplicate a virtual_router_id on the same network interface, there is a special case when using unicasting if the unicast peers for the vrrp instances with duplicated virtual_router_ids on the network interface do not overlap, in which case virtual_router_ids can be duplicated. 
    # It is also possible to duplicate virtual_router_ids on an interface with multicasting if different multicast addresses are used (see mcast_dst_ip).
    #---------------------------------------------------------------------
    virtual_router_id ${ROUTER_ID}

    #---------------------------------------------------------------------
    # for electing MASTER, highest priority wins.
    # The valid range of values for priority is [1-255], with priority 255 meaning "address owner".
    # To be MASTER, it is recommended to make this 50 more than on other machines. All systems should have different priorities in order to make behaviour deterministic. If you want to stop a higher priority instance taking over as master when it starts, configure no_preempt rather than using equal priorities.
    # If no_accept is configured (or vrrp_strict which also sets no_accept mode), then unless the vrrp_instance has priority 255, the system will not receive packets addressed to the VIPs/eVIPs, and the VIPs/eVIPs can only be used for routeing purposes. Further, if an instance has priority 255 configured, the priority cannot be reduced by track_scripts, track_process etc, and likewise track_scripts etc cannot increase the priority to 255 if the configured priority is not 255.
    #---------------------------------------------------------------------
    priority ${PRIORITY}

    #---------------------------------------------------------------------
    # Note: authentication was removed from the VRRPv2 specification by RFC3768 in 2004.
    # Use of this option is non-compliant and can cause problems; avoidusing if possible, except when using unicast, where it can be helpful.
    #---------------------------------------------------------------------
    authentication {
      
        #---------------------------------------------------------------------
        # PASS|AH, PASS - Simple password (suggested) | AH - IPSEC (not recommended)
        #---------------------------------------------------------------------
        auth_type PASS

        #---------------------------------------------------------------------
        # Password for accessing vrrpd. Should be the same on all machines. Only the first eight (8) characters are used.
        #---------------------------------------------------------------------
        auth_pass ${AUTH_PASS}
    }

    #---------------------------------------------------------------------
    # addresses add|del on change to MASTER, to BACKUP. With the same entries on other machines,  the opposite transition will be occurring.  For virtual_ipaddress, virtual_ipaddress_excluded,  virtual_routes and virtual_rules most of the options  match the options of the command ip address/route/rule add.  The track_group option only applies to static addresses/routes/rules.  no_track is specific to keepalived and means that the  vrrp_instance will not transition out of master state  if the address/route/rule is deleted and the address/route/rule  will not be reinstated until the vrrp instance next transitions  to master.
    # <LABEL>: is optional and creates a name for the alias. For compatibility with "ifconfig", it should be of the form <realdev>:<anytext>, for example eth0:1 for an alias on eth0.
    # <SCOPE>: ("site"|"link"|"host"|"nowhere"|"global") preferred_lft is set to 0 to deprecate IPv6 addresses (this is the default if the address mask is /128). Use "preferred_lft forever" to specify that a /128 address should not be deprecated. NOTE: care needs to be taken if dev is specified for an address and your network uses MAC learning switches. The VRRP protocol ensures that the source MAC address of the interface sending adverts is maintained in the MAC cache of switches; however by default this will not work for the MACs of any VIPs/eVIPs that are configured on different interfaces from the interface on which the VRRP instance is configured, since the interface, especially if it is a VMAC interface, will only send using the MAC address of the interface in response to ARP requests. This may mean that the interface MAC addresses may time out in the MAC caches of switches. In order to avoid this, use the garp_extra_if or garp_extra_if_vmac options to send periodic GARP/ND messages on those interfaces.
    #---------------------------------------------------------------------
    virtual_ipaddress {
        ${APISERVER_VIP}
    }

    #---------------------------------------------------------------------
    # add a tracking script to the interface (<SCRIPT_NAME> is the name of the vrrp_track_script entry) The same principle as track_interface can be applied to track_script entries, except that an unspecified weight means that the default weight declared in the script will be used (which itself defaults to 0). reverse causes the direction of the adjustment of the priority to be reversed.
    #---------------------------------------------------------------------
    track_script {
        kube-api-lb-script
    }
}
EOF
cat <<EOF | sudo tee /etc/keepalived/check_apiserver.sh > /dev/null
#!/bin/sh

errorExit() {
    echo "*** $*" 1>&2
    exit 1
}

curl --silent --max-time 2 --insecure https://localhost:${APISERVER_DEST_PORT}/ -o /dev/null || errorExit "Error GET https://localhost:${APISERVER_DEST_PORT}/"
if ip addr | grep -q ${APISERVER_VIP}; then
    curl --silent --max-time 2 --insecure https://${APISERVER_VIP}:${APISERVER_DEST_PORT}/ -o /dev/null || errorExit "Error GET https://${APISERVER_VIP}:${APISERVER_DEST_PORT}/"
fi
EOF

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg >/dev/null
# /etc/haproxy/haproxy.cfg
#---------------------------------------------------------------------
# Global settings
#---------------------------------------------------------------------
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon

    # Default SSL material locations
    ca-base /etc/kubernetes/pki
    crt-base /etc/kubernetes/pki
    ssl-server-verify none

#---------------------------------------------------------------------
# common defaults that all the 'listen' and 'backend' sections will
# use if not designated in their block
#---------------------------------------------------------------------
defaults
    mode                    http
    log                     global
    option                  httplog
    option                  dontlognull
    option http-server-close
    option forwardfor       except 127.0.0.0/8
    option                  redispatch
    retries                 1
    timeout http-request    10s
    timeout queue           20s
    timeout connect         5s
    timeout client          20s
    timeout server          20s
    timeout http-keep-alive 10s
    timeout check           10s

#---------------------------------------------------------------------
# apiserver frontend which proxys to the control plane nodes
#---------------------------------------------------------------------
frontend main
    bind *:${APISERVER_DEST_PORT}
    mode tcp
    option tcplog
    default_backend apiserver

#---------------------------------------------------------------------
# round robin balancing for apiserver
#---------------------------------------------------------------------
backend apiserver
    mode tcp
    option httpchk GET /healthz
    http-check expect status 200
    option ssl-hello-chk
    balance     roundrobin
        server ${HOST1_ID} ${HOST1_ADDRESS}:${APISERVER_SRC_PORT} check
        server ${HOST2_ID} ${HOST2_ADDRESS}:${APISERVER_SRC_PORT} check
        # [...]
EOF

# sudo mkdir -p /etc/kubernetes/manifests
# sudo cp haproxy.yaml /etc/kubernetes/manifests/haproxy.yaml
# sudo cp keepalived.yaml /etc/kubernetes/manifests/keepalived.yaml

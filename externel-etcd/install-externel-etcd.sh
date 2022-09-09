#!/usr/bin/env bash

# dns-server config
dns-server/keepalive.sh
dns-server/haproxy.sh

# Run the services as static pods
cp dns-server/keepalived.yaml /etc/kubernetes/manifests/keepalived.yaml
cp dns-server/haproxy.yaml /etc/kubernetes/manifests/haproxy.yaml


cat <<EOF > /etc/systemd/system/kubelet.service.d/20-etcd-service-manager.conf
[Service]
ExecStart=
# Replace "systemd" with the cgroup driver of your container runtime. The default value in the kubelet is "cgroupfs".
# Replace the value of "--container-runtime-endpoint" for a different container runtime if needed.
ExecStart=/usr/bin/kubelet \
--address=127.0.0.1 \
--pod-manifest-path=/etc/kubernetes/manifests/ \
--cgroup-driver=systemd \
--kubelet-cgroups=/system.slice \
--container-runtime=remote \
--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock
Restart=always
EOF

systemctl daemon-reload
systemctl restart kubelet

kubeadm init phase certs etcd-ca
kubeadm init phase certs etcd-server --config externel-etcd-config.yaml
kubeadm init phase certs etcd-peer --config externel-etcd-config.yaml
kubeadm init phase certs etcd-healthcheck-client --config externel-etcd-config.yaml
kubeadm init phase certs apiserver-etcd-client --config externel-etcd-config.yaml
 
kubeadm init phase kubelet-start
kubeadm init phase etcd local --config externel-etcd-config.yaml

# copy cert to other control-plane
CONTROL_PLANE_IPS="10.0.0.3 10.0.0.4 10.0.0.5"
for ip in ${CONTROL_PLANE_IPS}; do
   ssh root@$host mkdir -p /etc/kubernetes/pki/etcd
   scp /etc/kubernetes/pki/ca.crt root@$ip:/etc/kubernetes/pki/ca.crt
   scp /etc/kubernetes/pki/ca.key root@$ip:/etc/kubernetes/pki/ca.key
   scp /etc/kubernetes/pki/sa.key root@$ip:/etc/kubernetes/pki/sa.key
   scp /etc/kubernetes/pki/sa.pub root@$ip:/etc/kubernetes/pki/sa.pub
   scp /etc/kubernetes/pki/front-proxy-ca.crt root@$ip:/etc/kubernetes/pki/front-proxy-ca.crt
   scp /etc/kubernetes/pki/front-proxy-ca.key root@$ip:/etc/kubernetes/pki/front-proxy-ca.key
   scp /etc/kubernetes/pki/etcd/ca.crt root@$ip:/etc/kubernetes/pki/etcd/ca.crt
   # Skip the next line if you are using external etcd
   scp /etc/kubernetes/pki/etcd/ca.key root@$ip:/etc/kubernetes/pki/etcd/ca.key
done

#!/bin/bash

cat << EOF && sleep 1
Start the kubernetes installation.

EOF

# Root permission check
if [ "$(id -u)" -ne 0 ] || [ "$(id -g)" -ne 0 ]; then
cat << EOF
Error:
  To install kubernetes, you must login as root.

Run the following command :
  sudo -E -s

Please login as root and try again

EOF
exit 0
fi

# get env
usage() {
  cat <<EOF
Usage:
  install.sh [flag]

Available Flags:
  -t, --type (required)                Enter control-plane or node  
  -A, --api-endpoint (required)        Enter api endpoint 

EOF
}

declare -A hyphen_list=()
declare -A dhyphen_list=()

HYPHEN_FLAGS=("t" "A")
DHYPHEN_FLAGS=("type" "api-endpoint")

if [ $# -eq 0 ]; then
  usage
  exit 0
fi

is_type=0
is_api_endpoint=0
while [ $# -gt 0 ]; do
  is_exist=0
  if [[ $1 != "-"* ]]; then
    usage
    exit 0
  elif [[ $1 = "-"* ]] && [[ $1 != "--"* ]]; then
    input_flags="${1/-/}"
    if [ $input_flags == 't' ]; then
      is_type=1
    fi
    if [ $input_flags == 'A' ]; then
      is_api_endpoint=1
    fi
    for hyphen_flags in ${HYPHEN_FLAGS[*]}; do
      if [[ "$input_flags" = "$hyphen_flags" ]]; then
        if [ -z $2 ]; then
          usage
          exit 0
        fi
        hyphen_list[$hyphen_flags]=$2
        shift 2
        is_exist=1
        break
      fi
    done
    if [ $is_exist -eq 0 ]; then
      usage
      exit 0
    fi
  elif [[ $1 = "--"* ]]; then
    input_flags="${1/--/}"
    if [ $input_flags == 'type' ]; then
      is_type=1
    fi
    if [ $input_flags == 'api-endpoint' ]; then
      is_api_endpoint=1
    fi
    for dhyphen_flags in ${DHYPHEN_FLAGS[*]}; do
      if [[ "$dhyphen_flags" = "$input_flags" ]]; then
        if [ -z $2 ]; then
          usage
          exit 0
        fi
        dhyphen_list[$dhyphen_flags]=$2
        shift 2
        is_exist=1
        break
      fi
    done
    if [ $is_exist -eq 0 ]; then
      usage
      exit 0
    fi
  fi
done
if [ $is_type -eq 0 ] || [ $is_api_endpoint -eq 0 ]; then
  usage
  exit 0
fi

cat << EOF && sleep 1
#===================#
# configuration ... #
#===================#

EOF
# Swap disabled for the kubelet to work properly
sudo swapoff -a
sudo sed -ri 's/(.*swap.*)/#\1/' /etc/fstab

# Forwarding IPv4 and letting iptables see bridged traffic
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# edit sysctl config for node's iptables
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system > /dev/null 2>&1

cat << EOF && sleep 1
#===========================#
# Install container runtime #
#===========================#

EOF
ARCH=$(dpkg --print-architecture)
CONTAINERD_VERSION="v1.6.8"
RUNC_VERSION="v1.1.3"
CNI_PLUGINS_VERSION="v1.1.1"

# install containerd
wget -O containerd.tar.gz \
"https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION/v/}-linux-${ARCH}.tar.gz"
sudo tar Cxzvf /usr/local containerd.tar.gz && sudo rm -rf containerd.tar.gz

# install runc
wget -O runc \
"https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}"
sudo install -m 755 runc /usr/local/sbin/runc && sudo rm -rf runc

# install cni plugin
sudo mkdir -p /opt/cni/bin
wget -O cni.tgz \
"https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" 
sudo tar Cxzvf /opt/cni/bin cni.tgz && sudo rm -rf cni.tgz

# start containerd via systemd
sudo mkdir -p /usr/local/lib/systemd/system
sudo wget -O /usr/local/lib/systemd/system/containerd.service \
"https://raw.githubusercontent.com/containerd/containerd/main/containerd.service"

sudo systemctl daemon-reload
sudo systemctl enable --now containerd

# enable cri plugin and configure at containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo sed -n 'w /etc/containerd/config.toml' 
sudo sed -i 's/\(max_container_log_line_size = \).*/\1-1/' /etc/containerd/config.toml
sudo sed -i 's/\(SystemdCgroup = \).*/\1true/' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl restart containerd

cat << EOF && sleep 1
#====================#
# Install Kubernetes #
#====================#

EOF
ARCH=$(dpkg --print-architecture)
CRICTL_VERSION="v1.23.0"
KUBERNETES_VERSION="v1.23.0"
KUBELET_CONFIG_VERSION="v0.4.0"

# install crictl
wget -O crictl.tar.gz \
"https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
sudo tar Cxzvf /usr/local/bin crictl.tar.gz && sudo rm -rf crictl.tar.gz
# config crictl
cat << EOF | sudo tee /etc/crictl.yaml > /dev/null 
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: true
pull-image-on-create: true
EOF


# install kubectl kubelet kubeadm  
kube_list="kubeadm kubelet kubectl"
for kube_item in $kube_list; do
sudo wget -O /usr/local/bin/$kube_item \
"https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/$kube_item"
sudo chmod +x /usr/local/bin/$kube_item
done

# config kubelet uses systemd 
sudo wget -O /usr/local/lib/systemd/system/kubelet.service \
"https://raw.githubusercontent.com/kubernetes/release/${KUBELET_CONFIG_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service"
sudo sed -i "s:/usr/bin:/usr/local/bin:g" /usr/local/lib/systemd/system/kubelet.service

sudo mkdir -p /usr/local/lib/systemd/system/kubelet.service.d
sudo wget -O /usr/local/lib/systemd/system/kubelet.service.d/10-kubeadm.conf \
"https://raw.githubusercontent.com/kubernetes/release/${KUBELET_CONFIG_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf"
sudo sed -i "s:/usr/bin:/usr/local/bin:g" /usr/local/lib/systemd/system/kubelet.service.d/10-kubeadm.conf

sudo systemctl daemon-reload
sudo systemctl enable --now kubelet

# package for kubeadm
sudo apt-get update > /dev/null 
sudo apt-get install -y socat conntrack > /dev/null

if [ "${hyphen_list[t]}" = "control-plane" ] || [ "${dhyphen_list[type]}" = "control-plane" ]; then
cat << EOF && sleep 1
#===========================#
# Install the control plane #
#===========================#

EOF
# kubeadm init
sudo kubeadm init --config kubeadm-init.yaml -v 5

# To make kubectl work for your non-root user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# install addon for Pod networking (choose calico)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml
kubectl create -f calico-config.yaml

elif [ "${hyphen_list[t]}" = "node" ] || [ "${dhyphen_list[type]}" = "node" ]; then
cat << EOF && sleep 1
#==================#
# Install the node #
#==================#

EOF
# kubeadm join
sudo kubeadm join --config kubeadm-join.yaml -v 5
fi

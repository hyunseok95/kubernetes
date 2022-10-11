#!/bin/bash
cat << EOF && sleep 1
Start the Kubernetes installation.

EOF

# check root login 
if [ "$(id -u)" -ne 0 ] || [ "$(id -g)" -ne 0 ]; then
cat << EOF
To install Kubernetes, you need root privileges
Please try with the following command

Run the following command :
  sudo bash install.sh

EOF
exit 0
fi

# Check required packages
deb_required_package_list="tar wget sed socat conntrack"
rpm_required_package_list="tar wget sed socat conntrack-tools"
fast_runner=""
slow_runner=""

# which in deb
if [[ -n $(dpkg --version 2>/dev/null) ]]; then
  for deb_required_package in $deb_required_package_list; do
    if [ -z "$(dpkg --get-selections $deb_required_package 2>/dev/null)" ]; then
    fast_runner="$slow_runner $deb_required_package"
    slow_runner="$fast_runner"
    fi
  done
fi

# which in rpm
if [[ -n $(rpm --version 2>/dev/null) ]]; then
  for rpm_required_package in $rpm_required_package_list; do
    if [ -z "$(rpm -qa $rpm_required_package 2>/dev/null)" ]; then
    fast_runner="$slow_runner $rpm_required_package"
    slow_runner="$fast_runner"
    fi
  done
fi

if [ -n "$fast_runner" ]; then
cat << EOF
To install Kubernetes, you need to install some packages.

List of packages that need to be installed :
EOF
for i in $fast_runner; do
echo "  $i"
done
echo ""
exit 0
fi

# set env
cat << EOF
The following inputs are required to install Kubernetes
If there is no input, a default value is automatically selected.

EOF
server_ip=$(hostname -I | awk '{ print $1 }')

read -rp "1. Enter your server address [ $server_ip ]: " K8S_SERVER_IP
K8S_SERVER_IP=${K8S_SERVER_IP:-$server_ip}
read -rp "2. Enter install type either init or join [ init ]: " K8S_INSTALL_TYPE
K8S_INSTALL_TYPE=${K8S_INSTALL_TYPE:-"init"}

if [ "$K8S_INSTALL_TYPE" != "init" ] && [ "$K8S_INSTALL_TYPE" != "join" ]; then
cat << EOF
Please enter either init or join

EOF
exit 0
elif [ "$K8S_INSTALL_TYPE" = "join" ]; then
echo -n "3. Enter server token's hash: "
stty -echo
read -r GW_TOKEN_HASH
stty echo
echo ""
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

# add path /usr/local/bin at sudo
is_sudo_path=$(sudo awk '/secure_path/ {print}' /etc/sudoers | grep "/usr/local/bin")
if [[ -z $is_sudo_path ]]; then
sudo sed -i '/secure_path/{s%[/]%/usr/local/bin:/%;}' /etc/sudoers
fi

ARCH=$(uname -i)
[ "$ARCH" = "aarch64" ] && ARCH=arm64
[ "$ARCH" = "x86_64" ] && ARCH=amd64

cat << EOF && sleep 1
#===========================#
# Install container runtime #
#===========================#

EOF
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
sudo containerd config default | sudo sed -n 'w /etc/containerd/config.toml' 
sudo sed -i 's/\(max_container_log_line_size = \).*/\1-1/' /etc/containerd/config.toml
sudo sed -i 's/\(SystemdCgroup = \).*/\1true/' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl restart containerd

cat << EOF && sleep 1
#====================#
# Install Kubernetes #
#====================#

EOF
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

if [ "$K8S_INSTALL_TYPE" = "init" ]; then
cat << EOF && sleep 1
#==========================#
# Create the Control Plane #
#==========================#

EOF
# kubeadm init
sed -i "s/\(controlPlaneEndpoint: \).*/\1${K8S_SERVER_IP}:6443/" kubeadm-init.yaml
sudo kubeadm init --config kubeadm-init.yaml -v 5

# To make kubectl work for your non-root user
USERS_NAME=$(who am i | awk '{print $1}')
sudo mkdir -p /home/"$USERS_NAME"/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/"$USERS_NAME"/.kube/config
sudo chown "$USERS_NAME":"$USERS_NAME" /home/"$USERS_NAME"/.kube/config

# install addon for Pod networking (choose calico)
sudo -u "$USERS_NAME" kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml
sudo -u "$USERS_NAME" kubectl create -f calico-config.yaml

elif [ "$K8S_INSTALL_TYPE" = "join" ]; then
cat << EOF && sleep 1
#============================#
# Node join to Control Plane #
#============================#

EOF
# kubeadm join
sed -i "s/\(apiServerEndpoint: \).*/\1${K8S_SERVER_IP}:6443/" kubeadm-join.yaml
sed -i "s/- sha256:.*/- ${GW_TOKEN_HASH}/" kubeadm-join.yaml
sudo kubeadm join --config kubeadm-join.yaml -v 5
fi

# centos 설치시 일시적으로 방화벽을 꺼준다. 파드가 다 올라간 후에 방화벽 재 시작
# sudo systemctl stop firewalld
# sudo systemctl start firewalld

# 재 기동 오류시 방화벽 체인룰을 초기화 한다. 
# sudo iptables --flush && sudo iptables -t mangle --flush && sudo iptables -t nat --flush
# sudo systemctl restart containerd && sudo systemctl restart kubelet

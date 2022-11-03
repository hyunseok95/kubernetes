#!/usr/bin/env bash
#
# Perform installation of Kubernetes

K8S_LOCAL_SERVER_IP=''
K8S_GLOBAL_SERVER_ENDPOINT=''
K8S_INSTALL_TYPE=''
K8S_JOIN_TYPE=''
K8S_CRT_KEY=''
K8S_TOKEN=''
K8S_TOKEN_HASH=''

KUBERNETES_VERSION='v1.23.0'
KUBELET_CONFIG_VERSION='v0.4.0'
CONTAINERD_VERSION='v1.6.8'
CNI_PLUGINS_VERSION='v1.1.1'
CRICTL_VERSION='v1.23.0'
RUNC_VERSION='v1.1.3'

ARCH="$(uname -m)"
case "${ARCH}" in
aarch64)
  ARCH=arm64
  ;;
x86_64)
  ARCH=amd64
  ;;
esac

DISTRO=''
if [[ -n "$(dpkg --version 2>/dev/null)" ]]; then
  DISTRO='debian'
elif [[ -n $(rpm --version 2>/dev/null) ]]; then
  DISTRO='redhat'
fi

################################
# Pre-check before installation
# Globals:
#   ARCH
#   DISTRO
# Arguments:
#   None
# Outputs:
#   None
################################
pre_check() {
  declare -a deb_required_package_list
  declare -a rpm_required_package_list
  declare -a target_package_list

  deb_required_package_list=(tar curl sed socat conntrack ethtool)
  rpm_required_package_list=(tar curl sed socat conntrack-tools ethtool)

  info "Pre-checking..."

  # check root permission
  if [[ "$(id -u)" -ne 0 ]] || [[ "$(id -g)" -ne 0 ]]; then
    error "To install Kubernetes, you need root privileges. \nRun the following command: \n\n sudo ./install.sh"
    exit 1
  fi

  # check machine architecture
  if [[ "${ARCH}" != "arm64" ]] && [[ "${ARCH}" != "amd64" ]]; then
    error "Unsupported architecture"
    exit 1
  fi

  # check dependency package installation
  case "${DISTRO}" in
    debian)
      for deb_required_package in "${deb_required_package_list[@]}"; do
        if [ -z "$(dpkg --get-selections "$deb_required_package" 2>/dev/null)" ]; then
          target_package_list+=("${deb_required_package}")
        fi
      done
      ;;
    redhat)
      for rpm_required_package in "${rpm_required_package_list[@]}"; do
        if [ -z "$(rpm -qa "$rpm_required_package" 2>/dev/null)" ]; then
          target_package_list+=("${rpm_required_package}")
        fi
      done
      ;;
    *)
      error "Unsupported linux distribution"
      ;;
  esac
  if [[ "${#target_package_list[@]}" -ne 0 ]]; then
    error "To install Kubernetes, you need to install some packages. \nList of packages that need to be installed :"
    for target_package in "${target_package_list[@]}"; do
      echo "  $target_package"
    done
    echo ''
    exit 1
  fi
}

##########################
# Read values and set env
# Globals:
#   K8S_LOCAL_SERVER_IP
#   K8S_GLOBAL_SERVER_ENDPOINT
#   K8S_INSTALL_TYPE
#   K8S_TOKEN_HASH
# Arguments:
#   None
# Outputs:
#   None
##########################
set_env() {
  K8S_LOCAL_SERVER_IP="$(ip route get "$(ip route show 0.0.0.0/0 \
    | awk -F via '{ print $2 }' | awk '{ print $1 }')" \
    | awk -F src '{ print $2 }' | awk '{ print $1 }')"

  info "Set environment variables to install Kubernetes. \nDefault values are assigned automatically."

  read -rp '1. Enter your server endpoint [ '"${K8S_LOCAL_SERVER_IP}"':6443 ]: ' K8S_GLOBAL_SERVER_ENDPOINT
  K8S_GLOBAL_SERVER_ENDPOINT=${K8S_GLOBAL_SERVER_ENDPOINT:-$K8S_LOCAL_SERVER_IP':6443'}
  read -rp "2. Enter install type either init or join [ init ]: " K8S_INSTALL_TYPE
  K8S_INSTALL_TYPE=${K8S_INSTALL_TYPE:-"init"}
  
  case "${K8S_INSTALL_TYPE}" in
    init) 
      echo 
      ;;
    join)
      read -rp "3. Enter join type either control-plane or node [ node ]: " K8S_JOIN_TYPE
      K8S_JOIN_TYPE=${K8S_JOIN_TYPE:-"node"}
      case "${K8S_JOIN_TYPE}" in
        control-plane)
          echo -e '4. Enter the server certificate-key (e.g <' "$(kubeadm certs certificate-key)"' >)'
          read -rp ' : ' K8S_CRT_KEY 
          echo -e '5. Enter the server token (e.g < '"$(kubeadm token generate)"' >)'
          read -rp ' : ' K8S_TOKEN
          echo -e '6. Enter the server token'"'"'s hash value (e.g < sha:256:'"$(kubeadm certs certificate-key)"' >)'
          read -rp ' : ' K8S_TOKEN_HASH
          ;;
        node)
          echo -e '4. Enter the server token (e.g < '"$(kubeadm token generate)"' >)'
          read -rp ' : ' K8S_TOKEN
          echo -e '5. Enter the server token'"'"'s hash value (e.g < sha256:'"$(kubeadm certs certificate-key)"' >)'
          read -rp ' : ' K8S_TOKEN_HASH
          ;;
        *)
          error "Please enter either control-plane or node"
          exit 1
          ;;
      esac
      echo
      ;;
    *)
      error "Please enter either init or join"
      exit 1
      ;;
  esac
}

####################################
# Configure settings for Kubernetes
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   None
#####################################
configure() {
  info "Configuration ..."

  # Swap disabled for the kubelet to work properly
  sudo swapoff -a
  sudo cp /etc/fstab /etc/fstab.old 
  sudo awk '{ 
    if ($0 ~ /.*swap.*/ && $0 !~ /^#/) {
      print "# You MUST disable swap in order for the kubelet to work properly.\n# "$0;
    } else {
      print $0;
    }
  }' /etc/fstab.old | sudo sed -n 'w /etc/fstab'
  
  # Forwarding IPv4 and letting iptables see bridged traffic
  cat <<EOF | sudo sed -n 'w /etc/modules-load.d/k8s.conf'
overlay
br_netfilter
EOF
  sudo modprobe overlay
  sudo modprobe br_netfilter

  # edit sysctl config for node's iptables
  cat <<EOF | sudo sed -n 'w /etc/sysctl.d/k8s.conf'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sudo sysctl --system >/dev/null 2>&1

  # add path /usr/local/bin at sudo env
  sudo cp /etc/sudoers /etc/sudoers.old
  sudo awk '{ 
    if ($0 ~ /secure_path/ && $1 !~ /^#/) {
      if ($NF ~ /".*"/) {
        gsub(/"/, "", $0);
      } 
      if ($NF !~ /\/usr\/local\/sbin/) {
        sub(/.+/, "&:/usr/local/sbin", $0);
      } 
      if ($NF !~ /\/usr\/local\/bin/) {
        sub(/.+/, "&:/usr/local/bin", $0);
      }
    }
    print $0;
  }' /etc/sudoers.old | sudo sed -n 'w /etc/sudoers'
}

##############################################
# Install and configure the container runtime.
# Globals:
#   ARCH
#   CONTAINERD_VERSION
#   RUNC_VERSION
#   CNI_PLUGINS_VERSION
# Arguments:
#   None
# Outputs:
#   None
##############################################
container_runtime() {
  info "Container runtime installation"

  # install cni plugin
  info "Install cni plugin:${CNI_PLUGINS_VERSION}"
  sudo mkdir -p /opt/cni/bin
  curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
    | sudo tar Cxz /opt/cni/bin

  # install runc
  if [[ -n $(which runc) ]] ; then
    notify "Skip install runc:${RUNC_VERSION} \n\n  Current runc version: \n  >> $(runc --v | sed -n '1p')"
  else
    info "Install runc:${RUNC_VERSION}"
    curl -Lo runc "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}"
    sudo install -m 755 runc /usr/local/sbin/runc && sudo rm -rf runc
  fi

  # install containerd
  if [[ -n $(which containerd) ]] ; then
    notify "Skip install containerd:${CONTAINERD_VERSION} \n\n  Current containerd version: \n  >> $(containerd -v)"
  else
    info "Install containerd:${CONTAINERD_VERSION}"
    curl -L "https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION/v/}-linux-${ARCH}.tar.gz" \
      | sudo tar Cxz /usr/local

    # Configure containerd via systemd
    sudo mkdir -p /usr/local/lib/systemd/system
    curl -sSL "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service" \
      | sudo sed -n 'w /usr/local/lib/systemd/system/containerd.service'

    # enable cri plugin and configure at containerd
    sudo mkdir -p /etc/containerd
    sudo containerd config default \
      | sed 's/\(max_container_log_line_size = \).*/\1-1/' \
      | sed 's/\(SystemdCgroup = \).*/\1true/' \
      | sudo sed -n 'w /etc/containerd/config.toml'

    sudo systemctl daemon-reload
    sudo systemctl enable --now containerd
  fi
}

#######################################
# Install and configure the kubernetes
# Globals:
#   ARCH
#   CRICTL_VERSION
#   KUBERNETES_VERSION
#   KUBELET_CONFIG_VERSION
# Arguments:
#   None
# Outputs:
#   None
#######################################
kubernetes() {
  info "Kubernetes installation"

  # install and config crictl
  info "Install crictl:${CRICTL_VERSION}"
  curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
    | sudo tar Cxz /usr/local/bin
  cat <<EOF | sudo sed -n 'w /etc/crictl.yaml'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: true
pull-image-on-create: true
EOF

  # install kubectl kubelet kubeadm
  for kube_item in kubeadm kubelet kubectl; do
    info "Install ${kube_item}:${KUBERNETES_VERSION}"
    sudo curl -Lo /usr/local/bin/"$kube_item" \
      "https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/$kube_item"
    sudo chmod +x /usr/local/bin/"$kube_item"
  done

  # config kubelet via systemd
  sudo mkdir -p /usr/local/lib/systemd/system/kubelet.service.d
  curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${KUBELET_CONFIG_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" \
    | awk '{ gsub(/\/usr\/bin/, "/usr/local/bin", $0); print}' \
    | sudo sed -n 'w /usr/local/lib/systemd/system/kubelet.service'
  curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${KUBELET_CONFIG_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" \
    | awk '{ gsub(/\/usr\/bin/, "/usr/local/bin", $0); print}' \
    | sudo sed -n 'w /usr/local/lib/systemd/system/kubelet.service.d/10-kubeadm.conf'

  sudo systemctl daemon-reload
  sudo systemctl enable --now kubelet
}

#################################
# Configure a Kubernetes cluster
# Globals:
#   K8S_GLOBAL_SERVER_ENDPOINT
#   K8S_INSTALL_TYPE
#   K8S_TOKEN_HASH
# Arguments:
#   File:
#    - kubeadm-init.yaml
#    - kubeadm-join.yaml
# Outputs:
#   None
#################################
clustering() {
  local certificate_key
  local token

  info "Kubernetes Clustering"

  case "${K8S_INSTALL_TYPE}" in
  init)
    info "Init the Control Plane"
    certificate_key="$(kubeadm certs certificate-key)"
    token="$(kubeadm token generate)"

    # kubeadm init
    sudo cp kubeadm-init.yaml kubeadm-init.yaml.old 
    sed 's/{{--GLOBAL_SERVER_ENDPOINT--}}/'"${K8S_GLOBAL_SERVER_ENDPOINT}"'/' kubeadm-init.yaml.old \
      | sed 's/{{--LOCAL_SERVER_IP--}}/'"${K8S_LOCAL_SERVER_IP}"'/' \
      | sed 's/{{--CRT_KEY--}}/'"${certificate_key}"'/' \
      | sed 's/{{--TOKEN--}}/'"${token}"'/' \
      | sudo sed -n 'w kubeadm-init.yaml'

    trap 'error "The kubernetes installation failed." && exit 1' ERR

    sudo kubeadm init --config kubeadm-init.yaml --upload-certs -v 5

    trap - ERR

    # To make kubectl work for root user
    mkdir -p /root/.kube
    sudo cp -i /etc/kubernetes/admin.conf /root/.kube/config
    sudo chown root:root /root/.kube/config

    # To make kubectl work for non-root user ( shell login )
    sudo mkdir -p /home/"$(logname)"/.kube
    sudo cp -i /etc/kubernetes/admin.conf /home/"$(logname)"/.kube/config
    sudo chown "$(logname)":"$(logname)" /home/"$(logname)"/.kube/config

    # install addon for Pod networking (choose calico)
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml" && sleep 5
    kubectl create -f calico-config.yaml

    # install k8s metrics-server
    kubectl create -f metrics-server.yaml && echo

    info 'you can join control-plane by using this certificate-key: \n\n'"  >> certificateKey: ${certificate_key}"
    
    info 'you can join control-plane or node by using this token: \n\n  >> token: '"${token}"'\n  >> token'"'"'s hash: sha256:'"$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')"
    
    info "The kubernetes installation is complete. \n\nRun the following command : \n  kubectl get pods -o wide -A"
    ;;
  join)
    info "Join to Control Plane"

    # kubeadm join
    sudo cp kubeadm-join.yaml kubeadm-join.yaml.old 

    case "${K8S_JOIN_TYPE}" in
      control-plane)
        sed 's/{{--GLOBAL_SERVER_ENDPOINT--}}/'"${K8S_GLOBAL_SERVER_ENDPOINT}"'/' kubeadm-join.yaml.old \
          | sed 's/{{--LOCAL_SERVER_IP--}}/'"${K8S_LOCAL_SERVER_IP}"'/' \
          | sed 's/{{--CRT_KEY--}}/'"${K8S_CRT_KEY}"'/' \
          | sed 's/{{--TOKEN--}}/'"${K8S_TOKEN}"'/' \
          | sed 's/{{--CA_CRT_HASH--}}/'"${K8S_TOKEN_HASH}"'/' \
          | sed '/taints: \[\]/d' \
          | sed 's/# //g' \
          | sudo sed -n 'w kubeadm-join.yaml'
        ;;
      node)
        sudo cp kubeadm-join.yaml kubeadm-join.yaml.old 
        sed 's/{{--GLOBAL_SERVER_ENDPOINT--}}/'"${K8S_GLOBAL_SERVER_ENDPOINT}"'/' kubeadm-join.yaml.old \
          | sed 's/{{--TOKEN--}}/'"${K8S_TOKEN}"'/' \
          | sed 's/{{--CA_CRT_HASH--}}/'"${K8S_TOKEN_HASH}"'/' \
          | sudo sed -n 'w kubeadm-join.yaml'
        ;;
      *)
        error "Please enter either control-plane or node"
        exit 1
        ;;
    esac

    trap 'error "The current node has failed to join the cluster." && exit 1' ERR

    sudo kubeadm join --config kubeadm-join.yaml -v 5

    trap - ERR

    info "The current node has successfully joined the cluster. "
    ;;
  *)
    error "Unsupported cluster type"
    ;;
  esac
}

info() {
  echo -e "\e[0m[\e[32mINFO\e[0m]: $*\n" >&1
  sleep 1
}

notify() {
  echo -e "\e[0m[\e[33mNOTIFY\e[0m]: $*\n" >&1
  sleep 1
}

error() {
  echo -e "\e[0m[\e[31mERROR\e[0m]: $*\n" >&1
  sleep 1
}

main() {
  info "Start the Kubernetes installation."

  pre_check

  set_env

  configure

  container_runtime

  kubernetes

  clustering
}

main "$@"

#!/usr/bin/env bash

VENVDIR=kubespray-venv
KUBESPRAYDIR=kubespray
ANSIBLE_VERSION=2.12

sudo apt-get update  
sudo apt-get install -y runc python3-virtualenv

git clone https://github.com/kubernetes-sigs/kubespray.git
virtualenv --python=$(which python3) $VENVDIR 
source $VENVDIR/bin/activate

cd $KUBESPRAYDIR
pip install -U -r requirements-$ANSIBLE_VERSION.txt

cp -rfp inventory/sample inventory/kubernetes-cluster
cat hosts.yaml | tee inventory/kubernetes-cluster/hosts.yaml > /dev/null
ansible-playbook -i inventory/kubernetes-cluster/hosts.yaml --become --become-user=root cluster.yml

# To make kubectl work for your non-root user
USERS_NAME=$(who am i | awk '{print $1}')
sudo mkdir -p /home/"$USERS_NAME"/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/"$USERS_NAME"/.kube/config
sudo chown "$USERS_NAME":"$USERS_NAME" /home/"$USERS_NAME"/.kube/config

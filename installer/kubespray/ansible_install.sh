#!/usr/bin/env bash

sudo apt-get update && sudo apt-get install -y runc

mkdir -p $HOME/workspace && cd $HOME/workspace
git clone https://github.com/kubernetes-sigs/kubespray.git
sudo apt-get update && sudo apt-get install -y python3-virtualenv

VENVDIR=kubespray-venv
KUBESPRAYDIR=kubespray
ANSIBLE_VERSION=2.12

virtualenv --python=$(which python3) $VENVDIR && source $VENVDIR/bin/activate

cd $KUBESPRAYDIR
pip install -U -r requirements-$ANSIBLE_VERSION.txt

cp -rfp inventory/sample inventory/kubernetes-cluster
vi inventory/kubernetes-cluster/hosts.yaml
ansible-playbook -i inventory/kubernetes-cluster/hosts.yaml --become --become-user=root cluster.yml

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
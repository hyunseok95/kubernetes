#!/usr/bin/env bash

$HOME/workspace/k8s/nfs/nfs-export.sh jenkins

chown 1000:1000 /nfs/jenkins
ls -n /nfs

kubectl apply -f $HOME/workspace/k8s/jenkins/volume-config.yaml

helm repo add jenkins https://charts.jenkins.io

helm repo update

jkopt1="--sessionTimeout=1440"
jkopt2="--sessionEviction=86400"
jvopt1="-Duser.timezone=Asia/Seoul"

helm install jenkins jenkins/jenkins \
-f $HOME/workspace/k8s/jenkins/config.yaml \
--set controller.jenkinsOpts="$jkopt1 $jkopt2" \
--set controller.javaOpts="$jvopt1"

kubectl apply -f $HOME/workspace/k8s/jenkins/rbac-config.yaml

#!/usr/bin/env bash

nfsdir=/nfs/$1
if [ $# -eq 0 ]; then
  echo "usage: nfs-export.sh <name>"; exit 0
fi

if [[ ! -d $nfsdir ]]; then
  mkdir -p $nfsdir
  chmod -R 777 $nfsdir
  echo "$nfsdir *(rw,sync,no_subtree_check)" >> /etc/exports
  exportfs -rav

  if [[ $(systemctl is-enabled nfs-server) -eq "disabled" ]]; then
    systemctl enable --now nfs-server
  fi
   systemctl restart nfs-server
fi


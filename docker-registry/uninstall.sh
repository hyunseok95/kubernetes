#!/usr/bin/env bash
if [ $# -eq 0 ]; then
  echo "usage: docker-registry-uninstall.sh <number of worker node>"; exit 0
fi

certs=/etc/docker/certs.d/192.168.56.100:8443
rm -rf /registry-image
rm -rf /etc/docker/certs
rm -rf $certs

for (( i=1; i<=$1; i++ ));
do
  sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.56.10$i rm -rf $certs
done

docker rm -f registry
docker rmi registry:2



#!/usr/bin/env bash
if [ $# -eq 0 ]; then
  echo "usage: docker-registry-install.sh <number of worker node>"; exit 0
fi

certs=/etc/docker/certs.d/192.168.56.100:8443
mkdir /registry-image
mkdir /etc/docker/certs
mkdir -p $certs
openssl req -x509 -config $(dirname "$0")/tls.csr -nodes -newkey rsa:4096 \
-keyout tls.key -out tls.crt -days 365 -extensions v3_req

for (( i=1; i<=$1; i++ ));
  do
    sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.56.10$i mkdir -p $certs
    sshpass -p root scp tls.crt 192.168.56.10$i:$certs
  done
  
cp tls.crt $certs
mv tls.* /etc/docker/certs

docker run -d \
  --restart=always \
  --name registry \
  -v /etc/docker/certs:/docker-in-certs:ro \
  -v /registry-image:/var/lib/registry \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:443 \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/docker-in-certs/tls.crt \
  -e REGISTRY_HTTP_TLS_KEY=/docker-in-certs/tls.key \
  -p 8443:443 \
  registry:2

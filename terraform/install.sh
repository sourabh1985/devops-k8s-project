#!/bin/bash -xe

yum install -y git docker

systemctl start docker
systemctl enable docker

usermod -aG docker ec2-user

curl -sfL https://get.k3s.io | sh -

chmod 644 /etc/rancher/k3s/k3s.yaml

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /home/ec2-user/.bashrc

ln -s /usr/local/bin/kubectl /usr/bin/kubectl

sleep 20
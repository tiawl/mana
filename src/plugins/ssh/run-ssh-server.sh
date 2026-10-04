#!/bin/sh

#docker build -t ssh .
docker run -d \
  --rm \
  --name sshd \
  --hostname sshd \
  -p 2222:22 \
  -v $HOME/.ssh/id_ed25519.pub:/home/sshuser/.ssh/authorized_keys:ro \
  ssh
#docker stop sshd

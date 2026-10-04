FROM alpine:3.24

USER root

RUN <<END_OF_RUN
    set -eux
    apk --no-cache add openssh-server
    ssh-keygen -A
    adduser -D -s /bin/sh sshuser
    passwd -u sshuser          # unlock the account

    # SSH config
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/custom.conf <<EOF
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF

    # Directory for authorized_keys (will be mounted or copied later)
    mkdir -p /home/sshuser/.ssh
    chown -R sshuser:sshuser /home/sshuser/.ssh
    chmod 700 /home/sshuser/.ssh
END_OF_RUN

ENTRYPOINT ["/bin/sh", "-c", "_sshd=\"$(command -v sshd)\"; exec \"${_sshd}\" -D -e \"$@\"", "--"]

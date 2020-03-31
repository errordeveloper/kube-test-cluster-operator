
# based on https://github.com/weaveworks/footloose/blob/e0a534425d93b0dc45e308b319b14622f60f39da/images/ubuntu18.04/Dockerfile
FROM ubuntu:18.04@sha256:bec5a2727be7fff3d308193cfde3491f8fba1a2ba392b7546b43a051853a341d as rootfs-builder

# Don't start any optional services except for the few we need.
RUN find /etc/systemd/system /lib/systemd/system \
      -path '*.wants/*' \
      -not -name '*journald*' \
      -not -name '*systemd-tmpfiles*' \
      -not -name '*systemd-user-sessions*' \
      -exec rm \{} \;

RUN apt-get update \
    && apt-get upgrade --yes \
    && apt-get install --yes --no-install-recommends \
      chrony \
      dbus \
      init \
      iproute2 \
      iptables \
      iputils-ping \
      kmod \
      net-tools \
      sudo \
      systemd \
    && SUDO_FORCE_REMOVE=yes apt-get remove --yes \
      dmsetup \
      sudo \
    && apt-get autoremove --yes \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN >/etc/machine-id
RUN >/var/lib/dbus/machine-id

RUN systemctl set-default multi-user.target
RUN systemctl mask \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      systemd-update-utmp.service \
      systemd-tmpfiles-setup.service \
      console-getty.service
RUN systemctl disable \
      networkd-dispatcher.service

# https://www.freedesktop.org/wiki/Software/systemd/ContainerInterface/
STOPSIGNAL SIGRTMIN+3


COPY configure.sh /tmp/configure.sh
RUN /tmp/configure.sh

FROM golang:1.14.1@sha256:08d16c1e689e86df1dae66d8ef4cec49a9d822299ec45e68a810c46cb705628d as agent-builder
ENV KATA_AGENT_IMPORT_PATH=github.com/kata-containers/agent
ARG KATA_AGENT_VERSION
RUN go get -d "${KATA_AGENT_IMPORT_PATH}" \
   && cd "${GOPATH}/src/${KATA_AGENT_IMPORT_PATH}" \
   && git checkout -q "${KATA_AGENT_VERSION}" \
   && make INIT=no SECCOMP=no \
   && make install DESTDIR=/out

FROM scratch as rootfs
COPY --from=rootfs-builder / /
COPY --from=agent-builder /out /

FROM ubuntu:18.04@sha256:bec5a2727be7fff3d308193cfde3491f8fba1a2ba392b7546b43a051853a341d as image-builder
RUN mkdir /out

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      gcc \
      libc-dev \
      parted \
      qemu-utils \
      udev \
    && true

COPY --from=rootfs / /in

COPY --from=linuxkit/kernel:4.19.104 /kernel /out/kernel-4.19.104-linuxkit
COPY --from=linuxkit/kernel:4.19.104 /kernel.tar /tmp/modules.tar
RUN tar -C /out -xf /tmp/modules.tar && rm -f /tmp/modules.tar

COPY make-image.sh /tmp/make-image.sh
COPY nsdax.gpl.c /tmp/nsdax.gpl.c

WORKDIR /tmp
CMD /tmp/make-image.sh -o /out/kata.img /in

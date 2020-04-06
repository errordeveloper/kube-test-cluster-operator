#!/bin/bash -x

set -o errexit
set -o pipefail
set -o nounset

mkdir -p /data/etc/sysctl.d /data/etc/modules-load.d /data/etc/systemd/system /data/etc/containerd

cat > /data/etc/sysctl.d/99-kubernetes-cri.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

cat > /data/etc/modules-load.d/99-containerd.conf << EOF
overlay
br_netfilter
vhost_vsock
EOF

cat > /data/etc/modules-load.d/99-kata.conf << EOF
vhost_vsock
EOF

mkdir -p /data/etc/systemd/system/kubelet.service.d

cat > /data/etc/systemd/system/kubelet.service.d/11-containerd.conf << EOF
[Service]
# Local metadata parameters: REGION, AWS_DEFAULT_REGION
EnvironmentFile=/etc/eksctl/metadata.env
# Global and static parameters: CLUSTER_DNS, NODE_LABELS, NODE_TAINTS
EnvironmentFile=/etc/eksctl/kubelet.env
# Local non-static parameters: NODE_IP, INSTANCE_ID
EnvironmentFile=/etc/eksctl/kubelet.local.env
ExecStart=
ExecStart=/usr/bin/kubelet \\
  --node-ip=\${NODE_IP} \\
  --node-labels=\${NODE_LABELS},alpha.eksctl.io/instance-id=\${INSTANCE_ID} \\
  --max-pods=\${MAX_PODS} \\
  --register-node=true --register-with-taints=\${NODE_TAINTS} \\
  --cloud-provider=aws \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \\
  --runtime-request-timeout=15m \\
  --network-plugin=cni \\
  --cni-bin-dir=/opt/cni/bin \\
  --cni-conf-dir=/etc/cni/net.d \\
  --kubeconfig=/etc/eksctl/kubeconfig.yaml \\
  --config=/etc/eksctl/kubelet.yaml
EOF

cat > /data/etc/systemd/system/containerd.service << EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Install]
WantedBy=multi-user.target

[Service]
#ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Delegate=yes
KillMode=process
Restart=always
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999
EOF

mkdir -p /data/etc/systemd/system/containerd.service.d

cat > /data/etc/systemd/system/containerd.service.d/11-kata.conf << EOF
[Service]
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/opt/kata/bin
EOF

cat > /data/etc/containerd/config.toml << EOF
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"
plugin_dir = ""
disabled_plugins = []
required_plugins = []
oom_score = 0

[grpc]
  address = "/run/containerd/containerd.sock"
  tcp_address = ""
  tcp_tls_cert = ""
  tcp_tls_key = ""
  uid = 0
  gid = 0
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[ttrpc]
  address = ""
  uid = 0
  gid = 0

[debug]
  address = ""
  uid = 0
  gid = 0
  level = "debug"

[metrics]
  address = ""
  grpc_histogram = false

[cgroup]
  path = ""

[timeouts]
  "io.containerd.timeout.shim.cleanup" = "5s"
  "io.containerd.timeout.shim.load" = "5s"
  "io.containerd.timeout.shim.shutdown" = "3s"
  "io.containerd.timeout.task.state" = "2s"

[plugins]
  [plugins."io.containerd.gc.v1.scheduler"]
    pause_threshold = 0.02
    deletion_threshold = 0
    mutation_threshold = 100
    schedule_delay = "0s"
    startup_delay = "100ms"
  [plugins."io.containerd.grpc.v1.cri"]
    disable_tcp_service = true
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"
    stream_idle_timeout = "4h0m0s"
    enable_selinux = false
    sandbox_image = "k8s.gcr.io/pause:3.1"
    stats_collect_period = 10
    systemd_cgroup = true
    enable_tls_streaming = false
    max_container_log_line_size = 16384
    disable_cgroup = false
    disable_apparmor = false
    restrict_oom_score_adj = false
    max_concurrent_downloads = 3
    disable_proc_mount = false
    [plugins."io.containerd.grpc.v1.cri".containerd]
      snapshotter = "overlayfs"
      default_runtime_name = "runc"
      no_pivot = false
      [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]
        runtime_type = ""
        runtime_engine = ""
        runtime_root = ""
        privileged_without_host_devices = false
      [plugins."io.containerd.grpc.v1.cri".containerd.untrusted_workload_runtime]
        runtime_type = ""
        runtime_engine = ""
        runtime_root = ""
        privileged_without_host_devices = false
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v1"
          runtime_engine = ""
          runtime_root = ""
          privileged_without_host_devices = false
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu]
          runtime_type = "io.containerd.kata-qemu.v2"
          pod_annotations = ["io.katacontainers.*"]
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu.options]
            ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-qemu.toml"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-fc]
          runtime_type = "io.containerd.kata-fc.v2"
          pod_annotations = ["io.katacontainers.*"]
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-fc.options]
            ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-fc.toml"
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
      max_conf_num = 1
      conf_template = ""
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = ["https://registry-1.docker.io"]
    [plugins."io.containerd.grpc.v1.cri".x509_key_pair_streaming]
      tls_cert_file = ""
      tls_key_file = ""
  [plugins."io.containerd.internal.v1.opt"]
    path = "/opt/containerd"
  [plugins."io.containerd.internal.v1.restart"]
    interval = "10s"
  [plugins."io.containerd.metadata.v1.bolt"]
    content_sharing_policy = "shared"
  [plugins."io.containerd.monitor.v1.cgroups"]
    no_prometheus = false
  [plugins."io.containerd.runtime.v1.linux"]
    shim = "containerd-shim"
    runtime = "runc"
    runtime_root = ""
    no_shim = false
    shim_debug = true
  [plugins."io.containerd.runtime.v2.task"]
    platforms = ["linux/amd64"]
  [plugins."io.containerd.service.v1.diff-service"]
    default = ["walking"]
  [plugins."io.containerd.snapshotter.v1.devmapper"]
    root_path = ""
    pool_name = ""
    base_image_size = ""
EOF

mkdir -p /data/opt/kata/share/defaults/kata-containers

cat > /data/opt/kata/share/defaults/kata-containers/configuration-qemu-debug.toml << EOF
# Copyright (c) 2017-2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

# XXX: WARNING: this file is auto-generated.
# XXX:
# XXX: Source file: "cli/config/configuration-qemu.toml.in"
# XXX: Project:
# XXX:   Name: Kata Containers
# XXX:   Type: kata

[hypervisor.qemu]
path = "/opt/kata/bin/qemu-system-x86_64"
kernel = "/opt/kata/share/kata-containers/vmlinuz.container"
image = "/opt/kata/share/kata-containers/kata-containers.img"
machine_type = "pc"

# Optional space-separated list of options to pass to the guest kernel.
# For example, use 'kernel_params = "vsyscall=emulate"' if you are having
# trouble running pre-2.15 glibc.
#
# WARNING: - any parameter specified here will take priority over the default
# parameter value of the same name used to start the virtual machine.
# Do not set values here unless you understand the impact of doing so as you
# may stop the virtual machine from booting.
# To see the list of default parameters, enable hypervisor debug, create a
# container and look for 'default-kernel-parameters' log entries.
kernel_params = "agent.ingnore_scsi_bus_scan_errors=true" # also: agent.ingnore_all_device_errors

# Path to the firmware.
# If you want that qemu uses the default firmware leave this option empty
firmware = ""

# Machine accelerators
# comma-separated list of machine accelerators to pass to the hypervisor.
# For example, 'machine_accelerators = "nosmm,nosmbus,nosata,nopit,static-prt,nofw"'
machine_accelerators=""

# Default number of vCPUs per SB/VM:
# unspecified or 0                --> will be set to 1
# < 0                             --> will be set to the actual number of physical cores
# > 0 <= number of physical cores --> will be set to the specified number
# > number of physical cores      --> will be set to the actual number of physical cores
default_vcpus = 1

# Default maximum number of vCPUs per SB/VM:
# unspecified or == 0             --> will be set to the actual number of physical cores or to the maximum number
#                                     of vCPUs supported by KVM if that number is exceeded
# > 0 <= number of physical cores --> will be set to the specified number
# > number of physical cores      --> will be set to the actual number of physical cores or to the maximum number
#                                     of vCPUs supported by KVM if that number is exceeded
# WARNING: Depending of the architecture, the maximum number of vCPUs supported by KVM is used when
# the actual number of physical cores is greater than it.
# WARNING: Be aware that this value impacts the virtual machine's memory footprint and CPU
# the hotplug functionality. For example, 'default_maxvcpus = 240' specifies that until 240 vCPUs
# can be added to a SB/VM, but the memory footprint will be big. Another example, with
# 'default_maxvcpus = 8' the memory footprint will be small, but 8 will be the maximum number of
# vCPUs supported by the SB/VM. In general, we recommend that you do not edit this variable,
# unless you know what are you doing.
default_maxvcpus = 0

# Bridges can be used to hot plug devices.
# Limitations:
# * Currently only pci bridges are supported
# * Until 30 devices per bridge can be hot plugged.
# * Until 5 PCI bridges can be cold plugged per VM.
#   This limitation could be a bug in qemu or in the kernel
# Default number of bridges per SB/VM:
# unspecified or 0   --> will be set to 1
# > 1 <= 5           --> will be set to the specified number
# > 5                --> will be set to 5
default_bridges = 1

# Default memory size in MiB for SB/VM.
# If unspecified then it will be set 2048 MiB.
default_memory = 2048
#
# Default memory slots per SB/VM.
# If unspecified then it will be set 10.
# This is will determine the times that memory will be hotadded to sandbox/VM.
#memory_slots = 10

# The size in MiB will be plused to max memory of hypervisor.
# It is the memory address space for the NVDIMM devie.
# If set block storage driver (block_device_driver) to "nvdimm",
# should set memory_offset to the size of block device.
# Default 0
#memory_offset = 0

# Specifies virtio-mem will be enabled or not.
# Please note that this option should be used with the command
# "echo 1 > /proc/sys/vm/overcommit_memory".
# Default false
#enable_virtio_mem = true

# Disable block device from being used for a container's rootfs.
# In case of a storage driver like devicemapper where a container's 
# root file system is backed by a block device, the block device is passed
# directly to the hypervisor for performance reasons. 
# This flag prevents the block device from being passed to the hypervisor, 
# 9pfs is used instead to pass the rootfs.
disable_block_device_use = false

# Shared file system type:
#   - virtio-9p (default)
#   - virtio-fs
shared_fs = "virtio-9p"

# Path to vhost-user-fs daemon.
virtio_fs_daemon = "/opt/kata/bin/virtiofsd"

# Default size of DAX cache in MiB
virtio_fs_cache_size = 1024

# Extra args for virtiofsd daemon
#
# Format example:
#   ["-o", "arg1=xxx,arg2", "-o", "hello world", "--arg3=yyy"]
#
# see 'virtiofsd -h' for possible options.
virtio_fs_extra_args = []

# Cache mode:
#
#  - none
#    Metadata, data, and pathname lookup are not cached in guest. They are
#    always fetched from host and any changes are immediately pushed to host.
#
#  - auto
#    Metadata and pathname lookup cache expires after a configured amount of
#    time (default is 1 second). Data is cached while the file is open (close
#    to open consistency).
#
#  - always
#    Metadata, data, and pathname lookup are cached in guest and never expire.
virtio_fs_cache = "always"

# Block storage driver to be used for the hypervisor in case the container
# rootfs is backed by a block device. This is virtio-scsi, virtio-blk
# or nvdimm.
block_device_driver = "virtio-scsi"

# Specifies cache-related options will be set to block devices or not.
# Default false
#block_device_cache_set = true

# Specifies cache-related options for block devices.
# Denotes whether use of O_DIRECT (bypass the host page cache) is enabled.
# Default false
#block_device_cache_direct = true

# Specifies cache-related options for block devices.
# Denotes whether flush requests for the device are ignored.
# Default false
#block_device_cache_noflush = true

# Enable iothreads (data-plane) to be used. This causes IO to be
# handled in a separate IO thread. This is currently only implemented
# for SCSI.
#
enable_iothreads = false

# Enable pre allocation of VM RAM, default false
# Enabling this will result in lower container density
# as all of the memory will be allocated and locked
# This is useful when you want to reserve all the memory
# upfront or in the cases where you want memory latencies
# to be very predictable
# Default false
#enable_mem_prealloc = true

# Enable huge pages for VM RAM, default false
# Enabling this will result in the VM memory
# being allocated using huge pages.
# This is useful when you want to use vhost-user network
# stacks within the container. This will automatically 
# result in memory pre allocation
#enable_hugepages = true

# Enable vhost-user storage device, default false
# Enabling this will result in some Linux reserved block type
# major range 240-254 being chosen to represent vhost-user devices.
enable_vhost_user_store = false

# The base directory specifically used for vhost-user devices.
# Its sub-path "block" is used for block devices; "block/sockets" is
# where we expect vhost-user sockets to live; "block/devices" is where
# simulated block device nodes for vhost-user devices to live.
vhost_user_store_path = "/var/run/kata-containers/vhost-user"

# Enable file based guest memory support. The default is an empty string which
# will disable this feature. In the case of virtio-fs, this is enabled
# automatically and '/dev/shm' is used as the backing folder.
# This option will be ignored if VM templating is enabled.
#file_mem_backend = ""

# Enable swap of vm memory. Default false.
# The behaviour is undefined if mem_prealloc is also set to true
#enable_swap = true

# This option changes the default hypervisor and kernel parameters
# to enable debug output where available. This extra output is added
# to the proxy logs, but only when proxy debug is also enabled.
# 
# Default false
enable_debug = true

# Disable the customizations done in the runtime when it detects
# that it is running on top a VMM. This will result in the runtime
# behaving as it would when running on bare metal.
# 
#disable_nesting_checks = true

# This is the msize used for 9p shares. It is the number of bytes 
# used for 9p packet payload.
#msize_9p = 8192

# If true and vsocks are supported, use vsocks to communicate directly
# with the agent and no proxy is started, otherwise use unix
# sockets and start a proxy to communicate with the agent.
# Default false
use_vsock = true

# If false and nvdimm is supported, use nvdimm device to plug guest image.
# Otherwise virtio-block device is used.
# Default is false
#disable_image_nvdimm = true

# VFIO devices are hotplugged on a bridge by default. 
# Enable hotplugging on root bus. This may be required for devices with
# a large PCI bar, as this is a current limitation with hotplugging on 
# a bridge. This value is valid for "pc" machine type.
# Default false
#hotplug_vfio_on_root_bus = true

# Before hot plugging a PCIe device, you need to add a pcie_root_port device.
# Use this parameter when using some large PCI bar devices, such as Nvidia GPU
# The value means the number of pcie_root_port
# This value is valid when hotplug_vfio_on_root_bus is true and machine_type is "q35"
# Default 0
#pcie_root_port = 2

# If vhost-net backend for virtio-net is not desired, set to true. Default is false, which trades off
# security (vhost-net runs ring0) for network I/O performance. 
#disable_vhost_net = true

#
# Default entropy source.
# The path to a host source of entropy (including a real hardware RNG)
# /dev/urandom and /dev/random are two main options.
# Be aware that /dev/random is a blocking source of entropy.  If the host
# runs out of entropy, the VMs boot time will increase leading to get startup
# timeouts.
# The source of entropy /dev/urandom is non-blocking and provides a
# generally acceptable source of entropy. It should work well for pretty much
# all practical purposes.
#entropy_source= "/dev/urandom"

# Path to OCI hook binaries in the *guest rootfs*.
# This does not affect host-side hooks which must instead be added to
# the OCI spec passed to the runtime.
#
# You can create a rootfs with hooks by customizing the osbuilder scripts:
# https://github.com/kata-containers/osbuilder
#
# Hooks must be stored in a subdirectory of guest_hook_path according to their
# hook type, i.e. "guest_hook_path/{prestart,postart,poststop}".
# The agent will scan these directories for executable files and add them, in
# lexicographical order, to the lifecycle of the guest container.
# Hooks are executed in the runtime namespace of the guest. See the official documentation:
# https://github.com/opencontainers/runtime-spec/blob/v1.0.1/config.md#posix-platform-hooks
# Warnings will be logged if any error is encountered will scanning for hooks,
# but it will not abort container execution.
#guest_hook_path = "/usr/share/oci/hooks"

[factory]
# VM templating support. Once enabled, new VMs are created from template
# using vm cloning. They will share the same initial kernel, initramfs and
# agent memory by mapping it readonly. It helps speeding up new container
# creation and saves a lot of memory if there are many kata containers running
# on the same host.
#
# When disabled, new VMs are created from scratch.
#
# Note: Requires "initrd=" to be set ("image=" is not supported).
#
# Default false
#enable_template = true

# Specifies the path of template.
#
# Default "/run/vc/vm/template"
#template_path = "/run/vc/vm/template"

# The number of caches of VMCache:
# unspecified or == 0   --> VMCache is disabled
# > 0                   --> will be set to the specified number
#
# VMCache is a function that creates VMs as caches before using it.
# It helps speed up new container creation.
# The function consists of a server and some clients communicating
# through Unix socket.  The protocol is gRPC in protocols/cache/cache.proto.
# The VMCache server will create some VMs and cache them by factory cache.
# It will convert the VM to gRPC format and transport it when gets
# requestion from clients.
# Factory grpccache is the VMCache client.  It will request gRPC format
# VM and convert it back to a VM.  If VMCache function is enabled,
# kata-runtime will request VM from factory grpccache when it creates
# a new sandbox.
#
# Default 0
#vm_cache_number = 0

# Specify the address of the Unix socket that is used by VMCache.
#
# Default /var/run/kata-containers/cache.sock
#vm_cache_endpoint = "/var/run/kata-containers/cache.sock"

[proxy.kata]
path = "/opt/kata/libexec/kata-containers/kata-proxy"

# If enabled, proxy messages will be sent to the system log
# (default: disabled)
enable_debug = true

[shim.kata]
path = "/opt/kata/libexec/kata-containers/kata-shim"

# If enabled, shim messages will be sent to the system log
# (default: disabled)
enable_debug = true

# If enabled, the shim will create opentracing.io traces and spans.
# (See https://www.jaegertracing.io/docs/getting-started).
#
# Note: By default, the shim runs in a separate network namespace. Therefore,
# to allow it to send trace details to the Jaeger agent running on the host,
# it is necessary to set 'disable_new_netns=true' so that it runs in the host
# network namespace.
#
# (default: disabled)
#enable_tracing = true

[agent.kata]
# If enabled, make the agent display debug-level messages.
# (default: disabled)
enable_debug = true

# Enable agent tracing.
#
# If enabled, the default trace mode is "dynamic" and the
# default trace type is "isolated". The trace mode and type are set
# explicity with the 'trace_type=' and 'trace_mode=' options.
#
# Notes:
#
# - Tracing is ONLY enabled when 'enable_tracing' is set: explicitly
#   setting 'trace_mode=' and/or 'trace_type=' without setting 'enable_tracing'
#   will NOT activate agent tracing.
#
# - See https://github.com/kata-containers/agent/blob/master/TRACING.md for
#   full details.
#
# (default: disabled)
#enable_tracing = true
#
#trace_mode = "dynamic"
#trace_type = "isolated"

# Comma separated list of kernel modules and their parameters.
# These modules will be loaded in the guest kernel using modprobe(8).
# The following example can be used to load two kernel modules with parameters
#  - kernel_modules=["e1000e InterruptThrottleRate=3000,3000,3000 EEE=1", "i915 enable_ppgtt=0"]
# The first word is considered as the module name and the rest as its parameters.
# Container will not be started when:
#  * A kernel module is specified and the modprobe command is not installed in the guest
#    or it fails loading the module.
#  * The module is not available in the guest or it doesn't met the guest kernel
#    requirements, like architecture and version.
#
kernel_modules=[]


[netmon]
# If enabled, the network monitoring process gets started when the
# sandbox is created. This allows for the detection of some additional
# network being added to the existing network namespace, after the
# sandbox has been created.
# (default: disabled)
#enable_netmon = true

# Specify the path to the netmon binary.
path = "/opt/kata/libexec/kata-containers/kata-netmon"

# If enabled, netmon messages will be sent to the system log
# (default: disabled)
#enable_debug = true

[runtime]
# If enabled, the runtime will log additional debug messages to the
# system log
# (default: disabled)
enable_debug = true
#
# Internetworking model
# Determines how the VM should be connected to the
# the container network interface
# Options:
#
#   - macvtap
#     Used when the Container network interface can be bridged using
#     macvtap.
#
#   - none
#     Used when customize network. Only creates a tap device. No veth pair.
#
#   - tcfilter
#     Uses tc filter rules to redirect traffic from the network interface
#     provided by plugin to a tap interface connected to the VM.
#
internetworking_model="tcfilter"

# disable guest seccomp
# Determines whether container seccomp profiles are passed to the virtual
# machine and applied by the kata agent. If set to true, seccomp is not applied
# within the guest
# (default: true)
disable_guest_seccomp=true

# If enabled, the runtime will create opentracing.io traces and spans.
# (See https://www.jaegertracing.io/docs/getting-started).
# (default: disabled)
#enable_tracing = true

# If enabled, the runtime will not create a network namespace for shim and hypervisor processes.
# This option may have some potential impacts to your host. It should only be used when you know what you're doing.
# 'disable_new_netns' conflicts with 'enable_netmon'
# 'disable_new_netns' conflicts with 'internetworking_model=tcfilter' and 'internetworking_model=macvtap'. It works only
# with 'internetworking_model=none'. The tap device will be in the host network namespace and can connect to a bridge
# (like OVS) directly.
# If you are using docker, 'disable_new_netns' only works with 'docker run --net=none'
# (default: false)
#disable_new_netns = true

# if enabled, the runtime will add all the kata processes inside one dedicated cgroup.
# The container cgroups in the host are not created, just one single cgroup per sandbox.
# The runtime caller is free to restrict or collect cgroup stats of the overall Kata sandbox.
# The sandbox cgroup path is the parent cgroup of a container with the PodSandbox annotation.
# The sandbox cgroup is constrained if there is no container type annotation.
# See: https://godoc.org/github.com/kata-containers/runtime/virtcontainers#ContainerType
sandbox_cgroup_only=false

# Enabled experimental feature list, format: ["a", "b"].
# Experimental features are features not stable enough for production,
# they may break compatibility, and are prepared for a big version bump.
# Supported experimental features:
# (default: [])
experimental=[]
EOF

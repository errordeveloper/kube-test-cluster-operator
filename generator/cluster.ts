// TODO: import jk's kubernetes types

enum roles {
    master = "master",
    node = "node",
}

enum secretNames {
    joinToken = "join-token",
    kubeconfig = "kubeconfig",
}

enum ports {
    kubernetesAPI = 6443,
}

export enum runtimeClasses {
    kataQemu = "kata-qemu",
    kataFirecracker = "kata-fc",
}

export enum kataConfigs {
    qemu = "/opt/kata/share/defaults/kata-containers/configuration-qemu.toml",
    qemuDebug = "/opt/kata/share/defaults/kata-containers/configuration-qemu-debug.toml",

    default = qemuDebug,
}

export enum kataImages {
    customUbuntu = "/var/lib/images/vm/kata-agent-ubuntu.img",

    default = customUbuntu,
}

export enum kataKernels {
    linuxkit_5_4_19 = "/var/lib/images/kernel/linuxkit/vmlinuz-5.4.19-linuxkit",
    linuxkit_4_19_104 = "/var/lib/images/kernel/linuxkit/vmlinuz-4.19.104-linuxkit",

    default = linuxkit_5_4_19,
}

export interface KubernetesClusterSpec {
    name: string
    namespace: string
    image: string
    nodes: number
    runtime?: RuntimeSpec
    withImageCache?: boolean
}

export interface RuntimeSpec {
    class?: runtimeClasses
    kata?: KataRuntimeSpec
}

export interface KataRuntimeSpec {
    config?: kataConfigs
    image?: kataImages
    kernel?: kataKernels
}

export class KubernetesCluster {
    private cluster: KubernetesClusterSpec

    private items: object[]

    constructor(cluster: KubernetesClusterSpec) {
        this.cluster = cluster
        this.items = []
    }

    private makeMetadata({ roleLabel, nameSuffix }: { roleLabel?: roles; nameSuffix?: string } = {}) {
        const meta = {
            namespace: this.cluster.namespace,
            labels: {
                cluster: this.cluster.name,
                role: roleLabel,
            },
        }

        if (nameSuffix) {
            return Object.assign({}, meta, { name: `${this.cluster.name}-${nameSuffix}` })
        } else {
            return Object.assign({}, meta, { name: this.cluster.name })
        }
    }

    private getMemoryAndCPU(role: roles): [number, number] {
                // TODO: expose these to the API
                let memory = 5120
                if (role === roles.node) {
                    memory = 8192
                }

                const cpus = 2

                return [memory, cpus]
    }

    private makeKataAnnotations(role: roles) {
        const keyPrefix = "io.katacontainers.config"

        // TODO: this shouldn't be done here, we should fix the hotplug issue

        let [memory, cpus] = this.getMemoryAndCPU(role)

        return {
            [`${keyPrefix}_path`]: this.cluster.runtime?.kata?.config || kataConfigs.default,
            [`${keyPrefix}.hypervisor.image`]: this.cluster.runtime?.kata?.image || kataImages.default,
            [`${keyPrefix}.hypervisor.kernel`]: this.cluster.runtime?.kata?.kernel || kataKernels.default,
            // TODO: check if CONFIG_MEMORY_HOTPLUG is set, as kata relies on that;
            // normally one should use container resource limits/request
            [`${keyPrefix}.hypervisor.default_memory`]: `${memory}`,
            [`${keyPrefix}.hypervisor.default_vcpus`]: `${cpus}`,
        }
    }

    private makeAPIService(): void {
        const metadata = this.makeMetadata({roleLabel: roles.master})

        this.items.push({
            apiVersion: "v1",
            kind: "Service",
            metadata,
            spec: {
                ports: [
                    {
                        port: ports.kubernetesAPI,
                        protocol: "TCP",
                        targetPort: ports.kubernetesAPI
                    }
                ],
                selector: metadata.labels,
                sessionAffinity: "None",
                type: "ClusterIP"
            }
        })
    }

    private makeServiceAccount(role: roles): void {
        const metadata = this.makeMetadata({roleLabel: role, nameSuffix: role})

        this.items.push({
            apiVersion: "v1",
            kind: "ServiceAccount",
            metadata,
        })
    }

    private makeSecret(name: string): void {
        const metadata = this.makeMetadata({nameSuffix: name})

        this.items.push({
            apiVersion: "v1",
            kind: "Secret",
            metadata,
        })
    }

    private makeMasterRoleAndBinding(): void {
        const metadata = this.makeMetadata({roleLabel: roles.master, nameSuffix: roles.master})

        this.items.push({
            apiVersion: "rbac.authorization.k8s.io/v1",
            kind: "Role",
            metadata,
            rules: [
                {
                    apiGroups: [
                        ""
                    ],
                    resourceNames: [
                        `${this.cluster.name}-${secretNames.kubeconfig}`,
                        `${this.cluster.name}-${secretNames.joinToken}`,
                    ],
                    resources: [
                        "secrets"
                    ],
                    verbs: [
                        "get",
                        "patch"
                    ],
                }
            ]
        })

        this.items.push({
            apiVersion: "rbac.authorization.k8s.io/v1",
            kind: "RoleBinding",
            metadata,
            roleRef: {
                apiGroup: "rbac.authorization.k8s.io",
                kind: "Role",
                name: metadata.name,
            },
            subjects: [
                {
                    kind: "ServiceAccount",
                    name: metadata.name,
                }
            ]
        })
    }

    private makeDeployment(role: roles): void {
        const metadata = this.makeMetadata({roleLabel: role, nameSuffix: role})
        const spec = this.makeDeploymentSpec(metadata, role)

        this.items.push({
            apiVersion: "apps/v1",
            kind: "Deployment",
            metadata,
            spec,
        })
    }

    private makeDeploymentSpec(metadata: any, role: roles) {
        let replicas: number,
            kubeconfig: string,
            readinessProbe: object,
            volumes: object[],
            volumeMounts: object[]

        let annotations = {}

        let useKata = false;

        switch (this.cluster.runtime?.class) {
            case runtimeClasses.kataFirecracker:
            case runtimeClasses.kataQemu:
                useKata = true
                annotations = this.makeKataAnnotations(role)
                break;
        }

        const commonVolumes:object[] = []

        if  (this.cluster.withImageCache) {
             commonVolumes.push({
                 // TODO consider adding initContainers to wait for /var/images to have the right files, or at least some file
                 name: "images",
                 hostPath: {
                     type: "Directory",
                     path: "/var/lib/images",
                 },
             })
        }

        // TODO: generate kubeadm configs here?
        // TODO: consider generating scripts and systemd units also, so image can be more static...
        const projectedVolumeBase = {
            name: "metadata",
            downwardAPI: {
                items: [
                    {
                        fieldRef: {
                            fieldPath: "metadata.labels"
                        },
                        path: "labels",
                    },
                    {
                        fieldRef: {
                            fieldPath: "metadata.namespace"
                        },
                        path: "namespace",
                    },
                ]
            }
        }

        const commonVolumeMounts:object[] = [
            {
                name: "metadata",
                mountPath: "/etc/kubeadm/metadata",
            },
        ]

        if  (this.cluster.withImageCache) {
             commonVolumeMounts.push({
                 name: "images",
                 mountPath: "/images",
             })
        }

        if (!useKata) {
            commonVolumes.push(...[
                {
                    name: "lib-modules",
                    hostPath: {
                        type: "Directory",
                        path: "/lib/modules",
                    },
                },
                {
                    name: "xtables-lock",
                    hostPath: {
                        type: "FileOrCreate",
                        path: "/run/xtables.lock",
                    },
                }
            ])

            commonVolumeMounts.push(...[
                {
                    name: "lib-modules",
                    mountPath: "/lib/modules",
                    readOnly: true,
                },
                {
                    name: "xtables-lock",
                    mountPath: "/run/xtables.lock",
                },
            ])
        }

        if (useKata) {
            commonVolumes.push(...[
                {
                    name: "bpf-maps",
                    hostPath: {
                        type: "Directory",
                        path: "/sys/fs/bpf",
                    },
                },
            ])

            commonVolumeMounts.push(...[
                {
                    name: "bpf-maps",
                    mountPath: "/sys/fs/bpf",
                    mountPropagation: "Bidirectional", // required due to nesting, so that cilium pod can use
                },
            ])
        }


        switch (role) {
            case roles.master:
                replicas = 1

                kubeconfig = "/etc/kubernetes/admin.conf"

                readinessProbe = {
                    exec: {
                        command: [
                            "/usr/bin/is-master-ready.sh"
                        ]
                    },
                    failureThreshold: 500,
                    initialDelaySeconds: 30,
                    periodSeconds: 2,
                    successThreshold: 5,
                }

                volumes = [
                    ...commonVolumes,
                    projectedVolumeBase,
                    {
                        // TODO: make this part of the projected `/etc/kubeadm` volume
                        // also generate the contets of kubeconfig from here
                        name: "parent-management-cluster-service-account-token",
                        projected: {
                            sources: [
                                {
                                    serviceAccountToken: {
                                        path: "token"
                                    }
                                }
                            ]
                        }
                    },
                ]

                volumeMounts = [
                    ...commonVolumeMounts,
                    {
                        name: "parent-management-cluster-service-account-token",
                        mountPath: "/etc/parent-management-cluster/secrets",
                    },
                ]

                break;
            case roles.node:
                replicas = this.cluster.nodes

                kubeconfig = "/etc/kubernetes/kubelet.conf"

                readinessProbe = {
                    exec: {
                        command: [
                            "/usr/bin/is-node-ready.sh"
                        ]
                    },
                    failureThreshold: 500,
                    initialDelaySeconds: 30,
                    periodSeconds: 2,
                    successThreshold: 5,
                }

                volumes = [
                    ...commonVolumes,
                    projectedVolumeBase,
                    {
                        // TODO: make this part of the projected `/etc/kubeadm` volume
                        // also generate the contets of kubeconfig from here
                        name: "join-secret",
                        projected: {
                            sources: [
                                {
                                    secret: {
                                        name: `${this.cluster.name}-${secretNames.joinToken}`,
                                        optional: false,
                                    }
                                }
                            ]
                        }
                    },
                ]

                volumeMounts = [
                    ...commonVolumeMounts,
                    {
                        name: "join-secret",
                        mountPath: "/etc/kubeadm/secrets",
                    },
                ]

                break;
        }

        let [memory, cpus] = this.getMemoryAndCPU(role)

        const containers = [{
            name: "main",
            image: this.cluster.image,
            imagePullPolicy: "Always",
            command: [
                "/lib/systemd/systemd",
                `--unit=kubeadm@${role}.target`
            ],
            readinessProbe,
            env: [
                {
                    name: "KUBECONFIG",
                    value: kubeconfig,
                },
                {
                    name: "CONTAINER_RUNTIME_ENDPOINT",
                    value: "unix:///run/containerd/containerd.sock",
                },
            ],
            volumeMounts,
            securityContext: {
                privileged: true,
            },
            tty: true,
            resources: {
                requests: {
                  memory: `${memory}Mi`,
                  cpu:`${cpus}000m`,
                },
                limits: {
                  memory: `${memory}Mi`,
                  cpu: `${cpus}000m`,
                },
            }
        }]

        return {
            replicas,
            selector: {
                matchLabels: metadata.labels,
            },
            template: {
                metadata: {
                    labels: metadata.labels,
                    annotations,
                },
                spec: {
                    runtimeClassName: this.cluster.runtime?.class || undefined,
                    serviceAccountName: `${metadata.labels.cluster}-${role}`,
                    // systemd shaddows /run/secrets, so serviceaccount secrts are mounted differently
                    automountServiceAccountToken: false,
                    containers,
                    volumes,
                }
            }
        }
    }

    private makeList(items: any[]) {
        return {
            apiVersion: "v1",
            kind: "List",
            items,
        }
    }

    build() {
        this.makeAPIService()
        this.makeServiceAccount(roles.master)
        this.makeSecret(secretNames.kubeconfig)
        this.makeSecret(secretNames.joinToken)
        this.makeMasterRoleAndBinding()
        this.makeDeployment(roles.master)
        this.makeServiceAccount(roles.node)
        this.makeDeployment(roles.node)

        return this.makeList(this.items)
    }

    sonobuoy(image: string, args?: string[]) {
        const name = "sonobuoy"
        const metadata = Object.assign({},
            this.makeMetadata({nameSuffix: name}),
            {
                labels: {
                    "cluster-app": name,
                }
            },
        )

        const volumes = [
            {
                name: "kubeconfig",
                projected: {
                    sources: [
                        {
                            secret: {
                                name: `${this.cluster.name}-${secretNames.kubeconfig}`,
                                optional: false,
                            }
                        }
                    ]
                }
            },
        ]

        const volumeMounts = [
            {
                name: "kubeconfig",
                mountPath: "/etc/kubeadm/secrets",
            },
        ]

        let command = [ "/sonobuoy", "run", "--kubeconfig=/etc/kubeadm/secrets/kubeconfig", "--wait=1440" ]
        if (args) {
            command.push(...args)
        }

        const template = {
            // ? metadata: metadata.name, // job's pod selector is UID-based, so it only needs a name
            spec: {
                restartPolicy: "Never",
                volumes,
                containers: [
                    {
                        name,
                        image,
                        command,
                        volumeMounts,
                    }
                ]
            }
        }

        return {
            kind: "Job",
            apiVersion: "batch/v1",
            metadata,
            spec: {
                template,
            }
        }
    }
}

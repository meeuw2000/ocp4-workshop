#!/usr/bin/env bash
set -e

. /usr/local/bin/release-image.sh

mkdir --parents /etc/kubernetes/{manifests,bootstrap-configs,bootstrap-manifests}

bootkube_podman_run() {
    # we run all commands in the host-network to prevent IP conflicts with
    # end-user infrastructure.
    podman run --quiet --net=host "${@}"
}

MACHINE_CONFIG_OPERATOR_IMAGE=$(image_for machine-config-operator)
MACHINE_CONFIG_OSCONTENT=$(image_for machine-os-content)
MACHINE_CONFIG_ETCD_IMAGE=$(image_for etcd)
MACHINE_CONFIG_KUBE_CLIENT_AGENT_IMAGE=$(image_for kube-client-agent)
MACHINE_CONFIG_INFRA_IMAGE=$(image_for pod)

KUBE_ETCD_SIGNER_SERVER_IMAGE=$(image_for kube-etcd-signer-server)

CONFIG_OPERATOR_IMAGE=$(image_for cluster-config-operator)
KUBE_APISERVER_OPERATOR_IMAGE=$(image_for cluster-kube-apiserver-operator)
KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE=$(image_for cluster-kube-controller-manager-operator)
KUBE_SCHEDULER_OPERATOR_IMAGE=$(image_for cluster-kube-scheduler-operator)

OPENSHIFT_HYPERKUBE_IMAGE=$(image_for hyperkube)

CLUSTER_BOOTSTRAP_IMAGE=$(image_for cluster-bootstrap)

KEEPALIVED_IMAGE=$(image_for keepalived-ipfailover)
COREDNS_IMAGE=$(image_for coredns)
MDNS_PUBLISHER_IMAGE=$(image_for mdns-publisher)
HAPROXY_IMAGE=$(image_for haproxy-router)
BAREMETAL_RUNTIMECFG_IMAGE=$(image_for baremetal-runtimecfg)

# Now, as early as possible we replace the pause image and reload crio to use it, to ensure
# that we're using the pause image from our payload just like the primary cluster.
# The config should match the one generated by the MCO ideally:
# https://github.com/openshift/machine-config-operator/blob/e861ccb12f09c7c768d51fdf0a17879fcc9a87d5/templates/master/01-master-container-runtime/_base/files/crio.yaml
# But for now we're just changing the key bits: image and command.
# Perhaps down the line we change this to run something like:
# podman run machine-config-daemon bootstrap ... (passing the release image and the host rootfs)
sed --in-place --expression "s,pause_image *=.*,pause_image = \"${MACHINE_CONFIG_INFRA_IMAGE}\"," /etc/crio/crio.conf
sed --in-place --expression 's,pause_command *=.*,pause_command = "/usr/bin/pod",' /etc/crio/crio.conf
# Note crio today has a reload command but it just dies from the SIGHUP sent...
systemctl restart cri-o.service

mkdir --parents ./{bootstrap-manifests,manifests}

if [ ! -f cvo-bootstrap.done ]
then
	echo "Rendering Cluster Version Operator Manifests..."

	rm --recursive --force cvo-bootstrap

	bootkube_podman_run \
		--volume "$PWD:/assets:z" \
		"${RELEASE_IMAGE_DIGEST}" \
		render \
			--output-dir=/assets/cvo-bootstrap \
			--release-image="${RELEASE_IMAGE_DIGEST}"

	cp cvo-bootstrap/bootstrap/* bootstrap-manifests/
	cp cvo-bootstrap/manifests/* manifests/
	## FIXME: CVO should use `/etc/kubernetes/bootstrap-secrets/kubeconfig` instead
	cp auth/kubeconfig-loopback /etc/kubernetes/kubeconfig

	touch cvo-bootstrap.done
fi

if [ ! -f config-bootstrap.done ]
then
	echo "Rendering cluster config manifests..."

	rm --recursive --force config-bootstrap

	bootkube_podman_run \
		--volume "$PWD:/assets:z" \
		"${CONFIG_OPERATOR_IMAGE}" \
		/usr/bin/cluster-config-operator render \
		--config-output-file=/assets/config-bootstrap/config \
		--asset-input-dir=/assets/tls \
		--asset-output-dir=/assets/config-bootstrap

	cp config-bootstrap/manifests/* manifests/

	touch config-bootstrap.done
fi

if [ ! -f kube-apiserver-bootstrap.done ]
then
	echo "Rendering Kubernetes API server core manifests..."

	rm --recursive --force kube-apiserver-bootstrap

	bootkube_podman_run  \
		--volume "$PWD:/assets:z" \
		"${KUBE_APISERVER_OPERATOR_IMAGE}" \
		/usr/bin/cluster-kube-apiserver-operator render \
		--manifest-etcd-serving-ca=etcd-ca-bundle.crt \
		--manifest-etcd-server-urls=https://etcd-0.ocp.sandbox941.opentlc.com:2379,https://etcd-1.ocp.sandbox941.opentlc.com:2379,https://etcd-2.ocp.sandbox941.opentlc.com:2379 \
		--manifest-image="${OPENSHIFT_HYPERKUBE_IMAGE}" \
		--manifest-operator-image="${KUBE_APISERVER_OPERATOR_IMAGE}" \
		--asset-input-dir=/assets/tls \
		--asset-output-dir=/assets/kube-apiserver-bootstrap \
		--config-output-file=/assets/kube-apiserver-bootstrap/config \
		--cluster-config-file=/assets/manifests/cluster-network-02-config.yml

	cp kube-apiserver-bootstrap/config /etc/kubernetes/bootstrap-configs/kube-apiserver-config.yaml
	cp kube-apiserver-bootstrap/bootstrap-manifests/* bootstrap-manifests/
	cp kube-apiserver-bootstrap/manifests/* manifests/

	touch kube-apiserver-bootstrap.done
fi

if [ ! -f kube-controller-manager-bootstrap.done ]
then
	echo "Rendering Kubernetes Controller Manager core manifests..."

	rm --recursive --force kube-controller-manager-bootstrap

	bootkube_podman_run \
		--volume "$PWD:/assets:z" \
		"${KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE}" \
		/usr/bin/cluster-kube-controller-manager-operator render \
		--manifest-image="${OPENSHIFT_HYPERKUBE_IMAGE}" \
		--asset-input-dir=/assets/tls \
		--asset-output-dir=/assets/kube-controller-manager-bootstrap \
		--config-output-file=/assets/kube-controller-manager-bootstrap/config \
		--cluster-config-file=/assets/manifests/cluster-network-02-config.yml

	cp kube-controller-manager-bootstrap/config /etc/kubernetes/bootstrap-configs/kube-controller-manager-config.yaml
	cp kube-controller-manager-bootstrap/bootstrap-manifests/* bootstrap-manifests/
	cp kube-controller-manager-bootstrap/manifests/* manifests/

	touch kube-controller-manager-bootstrap.done
fi

if [ ! -f kube-scheduler-bootstrap.done ]
then
	echo "Rendering Kubernetes Scheduler core manifests..."

	rm --recursive --force kube-scheduler-bootstrap

	bootkube_podman_run \
		--volume "$PWD:/assets:z" \
		"${KUBE_SCHEDULER_OPERATOR_IMAGE}" \
		/usr/bin/cluster-kube-scheduler-operator render \
		--manifest-image="${OPENSHIFT_HYPERKUBE_IMAGE}" \
		--asset-input-dir=/assets/tls \
		--asset-output-dir=/assets/kube-scheduler-bootstrap \
		--config-output-file=/assets/kube-scheduler-bootstrap/config

	cp kube-scheduler-bootstrap/config /etc/kubernetes/bootstrap-configs/kube-scheduler-config.yaml
	cp kube-scheduler-bootstrap/bootstrap-manifests/* bootstrap-manifests/
	cp kube-scheduler-bootstrap/manifests/* manifests/

	touch kube-scheduler-bootstrap.done
fi

if [ ! -f mco-bootstrap.done ]
then
	echo "Rendering MCO manifests..."

	rm --recursive --force mco-bootstrap

	bootkube_podman_run \
		--user 0 \
		--volume "$PWD:/assets:z" \
		"${MACHINE_CONFIG_OPERATOR_IMAGE}" \
		bootstrap \
			--etcd-ca=/assets/tls/etcd-ca-bundle.crt \
			--etcd-metric-ca=/assets/tls/etcd-metric-ca-bundle.crt \
			--root-ca=/assets/tls/root-ca.crt \
			--kube-ca=/assets/tls/kube-apiserver-complete-client-ca-bundle.crt \
			--config-file=/assets/manifests/cluster-config.yaml \
			--dest-dir=/assets/mco-bootstrap \
			--pull-secret=/assets/manifests/openshift-config-secret-pull-secret.yaml \
			--etcd-image="${MACHINE_CONFIG_ETCD_IMAGE}" \
			--kube-client-agent-image="${MACHINE_CONFIG_KUBE_CLIENT_AGENT_IMAGE}" \
			--machine-config-operator-image="${MACHINE_CONFIG_OPERATOR_IMAGE}" \
			--machine-config-oscontent-image="${MACHINE_CONFIG_OSCONTENT}" \
			--infra-image="${MACHINE_CONFIG_INFRA_IMAGE}" \
			--keepalived-image="${KEEPALIVED_IMAGE}" \
			--coredns-image="${COREDNS_IMAGE}" \
			--mdns-publisher-image="${MDNS_PUBLISHER_IMAGE}" \
			--haproxy-image="${HAPROXY_IMAGE}" \
			--baremetal-runtimecfg-image="${BAREMETAL_RUNTIMECFG_IMAGE}" \
			--cloud-config-file=/assets/manifests/cloud-provider-config.yaml

	# Bootstrap MachineConfigController uses /etc/mcc/bootstrap/manifests/ dir to
	# 1. read the controller config rendered by MachineConfigOperator
	# 2. read the default MachineConfigPools rendered by MachineConfigOperator
	# 3. read any additional MachineConfigs that are needed for the default MachineConfigPools.
	mkdir --parents /etc/mcc/bootstrap /etc/mcs/bootstrap /etc/kubernetes/manifests /etc/kubernetes/static-pod-resources
	cp mco-bootstrap/bootstrap/manifests/* /etc/mcc/bootstrap/
	cp openshift/* /etc/mcc/bootstrap/
	# 4. read ImageContentSourcePolicy objects generated by the installer
	cp manifests/* /etc/mcc/bootstrap/
	cp auth/kubeconfig-kubelet /etc/mcs/kubeconfig
	cp mco-bootstrap/bootstrap/machineconfigoperator-bootstrap-pod.yaml /etc/kubernetes/manifests/
        if [ -d mco-bootstrap/baremetal/manifests ]; then
            cp mco-bootstrap/baremetal/manifests/* /etc/kubernetes/manifests/
            cp --recursive mco-bootstrap/baremetal/static-pod-resources/* /etc/kubernetes/static-pod-resources/
        fi
	if [ -d mco-bootstrap/openstack/manifests ]; then
		cp mco-bootstrap/openstack/manifests/* /etc/kubernetes/manifests/
		cp --recursive mco-bootstrap/openstack/static-pod-resources/* /etc/kubernetes/static-pod-resources/
	fi
	cp mco-bootstrap/manifests/* manifests/

	# /etc/ssl/mcs/tls.{crt, key} are locations for MachineConfigServer's tls assets.
	mkdir --parents /etc/ssl/mcs/
	cp tls/machine-config-server.crt /etc/ssl/mcs/tls.crt
	cp tls/machine-config-server.key /etc/ssl/mcs/tls.key

	touch mco-bootstrap.done
fi

# We originally wanted to run the etcd cert signer as
# a static pod, but kubelet could't remove static pod
# when API server is not up, so we have to run this as
# podman container.
# See https://github.com/kubernetes/kubernetes/issues/43292

echo "Starting etcd certificate signer..."

trap "podman rm --force etcd-signer" ERR

bootkube_podman_run \
	--name etcd-signer \
	--detach \
	--volume /opt/openshift/tls:/opt/openshift/tls:ro,z \
	"${KUBE_ETCD_SIGNER_SERVER_IMAGE}" \
	serve \
	--cacrt=/opt/openshift/tls/etcd-signer.crt \
	--cakey=/opt/openshift/tls/etcd-signer.key \
	--metric-cacrt=/opt/openshift/tls/etcd-metric-signer.crt \
	--metric-cakey=/opt/openshift/tls/etcd-metric-signer.key \
	--servcrt=/opt/openshift/tls/kube-apiserver-lb-server.crt \
	--servkey=/opt/openshift/tls/kube-apiserver-lb-server.key \
	--servcrt=/opt/openshift/tls/kube-apiserver-internal-lb-server.crt \
	--servkey=/opt/openshift/tls/kube-apiserver-internal-lb-server.key \
	--servcrt=/opt/openshift/tls/kube-apiserver-localhost-server.crt \
	--servkey=/opt/openshift/tls/kube-apiserver-localhost-server.key \
	--address=0.0.0.0:6443 \
	--insecure-health-check-address=0.0.0.0:6080 \
	--csrdir=/tmp \
	--peercertdur=26280h \
	--servercertdur=26280h \
	--metriccertdur=26280h

echo "Waiting for etcd cluster..."

# Wait for the etcd cluster to come up.
until bootkube_podman_run \
		--rm \
		--name etcdctl \
		--env ETCDCTL_API=3 \
		--volume /opt/openshift/tls:/opt/openshift/tls:ro,z \
		--entrypoint etcdctl \
		"${MACHINE_CONFIG_ETCD_IMAGE}" \
		--dial-timeout=10m \
		--cacert=/opt/openshift/tls/etcd-ca-bundle.crt \
		--cert=/opt/openshift/tls/etcd-client.crt \
		--key=/opt/openshift/tls/etcd-client.key \
		--endpoints=https://etcd-0.ocp.sandbox941.opentlc.com:2379,https://etcd-1.ocp.sandbox941.opentlc.com:2379,https://etcd-2.ocp.sandbox941.opentlc.com:2379 \
		endpoint health
do
	echo "etcdctl failed. Retrying in 5 seconds..."
	sleep 5
done

echo "etcd cluster up. Killing etcd certificate signer..."

podman rm --force etcd-signer
rm --force /etc/kubernetes/manifests/machineconfigoperator-bootstrap-pod.yaml

echo "Starting cluster-bootstrap..."

bootkube_podman_run \
	--rm \
	--volume "$PWD:/assets:z" \
	--volume /etc/kubernetes:/etc/kubernetes:z \
	"${CLUSTER_BOOTSTRAP_IMAGE}" \
	start --tear-down-early=false --asset-dir=/assets --required-pods="openshift-kube-apiserver/kube-apiserver,openshift-kube-scheduler/openshift-kube-scheduler,openshift-kube-controller-manager/kube-controller-manager,openshift-cluster-version/cluster-version-operator"

# Workaround for https://github.com/opencontainers/runc/pull/1807
touch /opt/openshift/.bootkube.done
echo "bootkube.service complete"
KUBERNETES_VERSIONS := 1.16.9 1.17.5 1.18.12 1.19.4 1.20.0-rc.0

image = errordeveloper/kubeadm:ubuntu-20.04-$(1)

define do-build
  docker image build \
	  --build-arg KUBERNETES_VERSION=$(1) \
	  --tag $(call image,$(1)) .

endef

define do-push
  docker image push $(call image,$(1))
  docker image inspect --format '{{(index .RepoTags 0)}} {{(index .RepoDigests 0)}}' $(call image,$(1)) > .digest_$(1)

endef

.PHONY: build push

build:
	$(foreach v,$(KUBERNETES_VERSIONS),$(call do-build,$(v)))

push: build
	$(foreach v,$(KUBERNETES_VERSIONS),$(call do-push,$(v)))
	cat .digest_* > .digest
	rm -f .digest_*

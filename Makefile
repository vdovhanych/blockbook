# PLATFORM is linux/amd64 or linux/arm64. Empty builds for the host and keeps the
# historic image names. A set platform gets its own image tags, because image_status.sh
# treats any fresh blockbook-build:latest as reusable and would otherwise skip the
# second architecture. --load publishes that image to the local engine: the deb image
# is FROM the bin image, and docker run cannot see an image left only in a Buildx
# container builder. The static docker CLI arch has to match the container, since the
# backend package build invokes it inside the image.
PLATFORM ?=
ifeq ($(PLATFORM),)
BIN_IMAGE = blockbook-build
DEB_IMAGE = blockbook-build-deb
DOCKER_BUILD_FLAGS =
DOCKER_RUN_FLAGS =
else
ifeq ($(filter linux/amd64 linux/arm64,$(PLATFORM)),)
$(error PLATFORM must be linux/amd64 or linux/arm64)
endif
BIN_IMAGE = blockbook-build-$(subst /,-,$(PLATFORM))
DEB_IMAGE = blockbook-build-deb-$(subst /,-,$(PLATFORM))
DOCKER_BUILD_FLAGS = --platform $(PLATFORM) --load
DOCKER_RUN_FLAGS = --platform $(PLATFORM)
endif
PACKAGER = $(shell id -u):$(shell id -g)
DOCKER_VERSION = 29.4.3
DOCKER_SHA256_AMD64 = bc9734a89d3edd15eeca8620961f6499ba69948814c85d7ac3488e34b3e16d01
DOCKER_SHA256_ARM64 = fdde3dbedbd8dc9e9e54a3172e682b4e69e740296e580542ea9ceacebbbf4f4c
DOCKER_ARCH = x86_64
DOCKER_SHA256 = $(DOCKER_SHA256_AMD64)
ifeq ($(PLATFORM),linux/arm64)
DOCKER_ARCH = aarch64
DOCKER_SHA256 = $(DOCKER_SHA256_ARM64)
endif
BASE_IMAGE = $$(awk -F= '$$1=="ID" { print $$2 ;}' /etc/os-release):$$(awk -F= '$$1=="VERSION_ID" { print $$2 ;}' /etc/os-release | tr -d '"')
NO_CACHE = false
TCMALLOC =
JEMALLOC = 1
PORTABLE = 0
ARGS ?=
GITCOMMIT ?= $(shell git describe --always --dirty 2>/dev/null)
# Forward the build-time override variables into Docker for build/test tooling.
# The prefix set is the single source of truth in build/bb-build-var-prefixes.txt,
# shared with .github/actions/export-env-vars and build/tools/templates.go.
# (BB_BUILD_ENV is forwarded separately via -e BB_BUILD_ENV=... on each docker run.)
BB_VAR_PREFIX_FILE := build/bb-build-var-prefixes.txt
BB_RPC_ENV := $(shell env | awk -F= 'NR==FNR{line=$$0;gsub(/[[:space:]]/,"",line);if(substr(line,1,3)=="BB_")pfx[line]=1;next}{for(p in pfx){if(index($$1,p)==1){print "-e " $$1;next}}}' $(BB_VAR_PREFIX_FILE) -)
# BB_STAGING is a standalone control var (no coin-alias suffix, like BB_BUILD_ENV):
# forward it too so its config-absent coin exemption applies inside the container.
BB_RPC_ENV := $(BB_RPC_ENV)$(if $(BB_STAGING), -e BB_STAGING)

TARGETS=$(subst .json,, $(shell ls configs/coins))

.PHONY: build build-debug test test-connectivity test-integration test-e2e test-all typescriptify deb

build: .bin-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) $(BB_RPC_ENV) -v "$(CURDIR):/src" -v "$(CURDIR)/build:/out" $(BIN_IMAGE) make build ARGS="$(ARGS)"

build-debug: .bin-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) $(BB_RPC_ENV) -v "$(CURDIR):/src" -v "$(CURDIR)/build:/out" $(BIN_IMAGE) make build-debug ARGS="$(ARGS)"

test: .bin-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) $(BB_RPC_ENV) -v "$(CURDIR):/src" --network="host" $(BIN_IMAGE) make test ARGS="$(ARGS)"

test-integration: .bin-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) $(BB_RPC_ENV) -v "$(CURDIR):/src" --network="host" $(BIN_IMAGE) make test-integration ARGS="$(ARGS)"

# `make test-e2e [coin] [url]` — e.g. `make test-e2e bitcoin https://btc.trezor.io`.
# Extra goals after test-e2e are consumed as positional args (coin, base URL)
# and turned into OPENAPI_COINS / BB_DEV_API_URL_HTTP_<coin> for the test runner.
ifeq (test-e2e,$(firstword $(MAKECMDGOALS)))
  E2E_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  ifneq ($(E2E_ARGS),)
    # no-op catch-all so make does not try to build the positional args as targets
%:
	@:
  endif
endif

test-e2e:
	@if [ ! -x tests/openapi/node_modules/.bin/redocly ]; then npm ci --prefix tests/openapi --prefer-offline --no-audit --no-fund; fi
	@coin="$(word 1,$(E2E_ARGS))"; url="$(word 2,$(E2E_ARGS))"; \
	if [ -n "$$coin" ]; then export OPENAPI_COINS="$$coin"; fi; \
	if [ -n "$$url" ]; then export "BB_DEV_API_URL_HTTP_$$(printf %s "$$coin" | tr - _)=$$url"; fi; \
	contrib/tests/run-openapi-tests.sh

test-connectivity: .bin-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) -e CONNECTIVITY_REGEX -e BB_TEST_BACKEND_CONNECTIVITY $(BB_RPC_ENV) -v "$(CURDIR):/src" --network="host" $(BIN_IMAGE) make test-connectivity ARGS="$(ARGS)"

typescriptify: .bin-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -v "$(CURDIR):/src" $(BIN_IMAGE) make typescriptify

test-all: .bin-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) -e BB_TEST_BACKEND_CONNECTIVITY $(BB_RPC_ENV) -v "$(CURDIR):/src" --network="host" $(BIN_IMAGE) make test-all ARGS="$(ARGS)"

deb-backend-%: .deb-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) $(BB_RPC_ENV) -v /var/run/docker.sock:/var/run/docker.sock -v "$(CURDIR):/src" -v "$(CURDIR)/build:/out" $(DEB_IMAGE) /build/build-deb.sh backend $* $(ARGS)

deb-blockbook-%: .deb-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) $(BB_RPC_ENV) -v "$(CURDIR):/src" -v "$(CURDIR)/build:/out" $(DEB_IMAGE) /build/build-deb.sh blockbook $* $(ARGS)

deb-%: .deb-image
	docker run -t --rm $(DOCKER_RUN_FLAGS) -e PACKAGER=$(PACKAGER) -e BB_BUILD_ENV=$(BB_BUILD_ENV) -e GITCOMMIT=$(GITCOMMIT) $(BB_RPC_ENV) -v /var/run/docker.sock:/var/run/docker.sock -v "$(CURDIR):/src" -v "$(CURDIR)/build:/out" $(DEB_IMAGE) /build/build-deb.sh all $* $(ARGS)

deb-blockbook-all: clean-deb $(addprefix deb-blockbook-, $(TARGETS))

$(addprefix all-, $(TARGETS)): all-%: clean-deb build-images deb-%

all: clean-deb build-images $(addprefix deb-, $(TARGETS))

build-images: clean-images
	$(MAKE) .bin-image .deb-image

.bin-image:
	@if [ $$(build/tools/image_status.sh $(BIN_IMAGE):latest build/docker) != "ok" ]; then \
		echo "Building image $(BIN_IMAGE) from $(BASE_IMAGE)"; \
		docker build $(DOCKER_BUILD_FLAGS) --no-cache=$(NO_CACHE) --build-arg TCMALLOC=$(TCMALLOC) --build-arg JEMALLOC=$(JEMALLOC) --build-arg BASE_IMAGE=$(BASE_IMAGE) --build-arg PORTABLE_ROCKSDB=$(PORTABLE) -t $(BIN_IMAGE) build/docker/bin; \
	else \
		echo "Image $(BIN_IMAGE) is up to date"; \
	fi

.deb-image: .bin-image
	@if [ $$(build/tools/image_status.sh $(DEB_IMAGE):latest build/docker) != "ok" ]; then \
		echo "Building image $(DEB_IMAGE)..."; \
		docker build $(DOCKER_BUILD_FLAGS) --no-cache=$(NO_CACHE) --build-arg DOCKER_VERSION=$(DOCKER_VERSION) --build-arg DOCKER_SHA256=$(DOCKER_SHA256) --build-arg DOCKER_ARCH=$(DOCKER_ARCH) --build-arg BIN_IMAGE=$(BIN_IMAGE) -t $(DEB_IMAGE) build/docker/deb; \
	else \
		echo "Image $(DEB_IMAGE) is up to date"; \
	fi

clean: clean-bin clean-deb

clean-all: clean clean-images

clean-bin:
	find build -maxdepth 1 -type f -executable -delete

clean-deb:
	rm -rf build/pkg-defs
	rm -f build/*.deb

clean-images: clean-bin-image clean-deb-image
	rm -f .bin-image .deb-image  # remove obsolete tag files

clean-bin-image:
	- docker rmi $(BIN_IMAGE)

clean-deb-image:
	- docker rmi $(DEB_IMAGE)

style:
	find . -name "*.go" -exec gofmt -w {} \;

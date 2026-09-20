# `make help` lists the targets. The tests run in ghcr.io/stealth-scale/bats-test, the
# image of the bats-test repository: bash at BASH_VERSION, bats-core at BATS_VERSION,
# kcov, with the checkout mounted read-only. DISTRO=fedora selects the glibc image with
# Fedora's own bash and bats, the platform stealth runs on.
#
#   make test
#   make test TARGET=tests/unit
#   make test BASH_VERSION=4.4 BATS_VERSION=1.7.0
#   make test DISTRO=fedora
#   make coverage
SHELL := bash
.DEFAULT_GOAL := help

RUNTIME      ?= podman
BASH_VERSION ?= 5.2
BATS_VERSION ?= 1.14.0
DISTRO       ?= alpine
ifeq ($(DISTRO),fedora)
IMAGE        ?= ghcr.io/stealth-scale/bats-test:fedora
else
IMAGE        ?= ghcr.io/stealth-scale/bats-test:bash$(BASH_VERSION)-bats$(BATS_VERSION)
endif
# The suites, not the bats libraries under tests/helpers, which bring suites of their own.
TARGET       ?= $(shell find tests -name '*.bats' -not -path 'tests/helpers/*' | sort)
BATS_FLAGS   ?= --print-output-on-failure
COVERAGE_MIN ?= 100
# A prefix of its own: bin/stealth looks for lib/ next to its bin/. The system layout,
# /usr/bin/stealth with /usr/lib/stealth, is the package's.
PREFIX       ?= /opt/stealth
SHELLCHECK   ?= shellcheck

SOURCES = $(wildcard src/bin/*) $(shell find src/lib -name '*.sh' 2>/dev/null | sort)
TESTS   = tests/helpers/stealth/load.bash $(wildcard tests/mocks/*.bash) $(TARGET) \
          $(shell find tests/fixtures -name '*.sh' 2>/dev/null | sort)

# As the calling user, no network, no capabilities, checkout read-only. coverage/ is
# the one writable mount, for kcov's report. The image is its own init: Ctrl+C and
# `podman stop` end a run, kcov included. BATS_LIB_PATH is where the tests find the
# helper and the bats libraries by name.
RUN = $(RUNTIME) run --rm --network=none --cap-drop=ALL --security-opt=label=disable \
      --user $(shell id -u):$(shell id -g) $(if $(filter podman,$(RUNTIME)),--userns=keep-id) \
      --env BATS_LIB_PATH=/code/tests/helpers \
      --volume "$(CURDIR):/code:ro" --workdir /code

.PHONY: help test coverage test-host lint docs check shell install uninstall clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'

test: ## Run TARGET in the image
	$(RUN) $(IMAGE) test $(BATS_FLAGS) --recursive $(TARGET)

coverage: ## Run TARGET under kcov; table per file, report in coverage/, fails under COVERAGE_MIN%
	rm -rf coverage && mkdir coverage
	$(RUN) --volume "$(CURDIR)/coverage:/code/coverage" $(IMAGE) coverage --min $(COVERAGE_MIN) $(COVERAGE_FLAGS) -- $(BATS_FLAGS) --recursive $(TARGET)

test-host: ## Run TARGET with the bats of this machine
	BATS_LIB_PATH=$(CURDIR)/tests/helpers bats $(BATS_FLAGS) --recursive $(TARGET)

lint: ## Run shellcheck over the sources, the helper and the tests
	$(SHELLCHECK) -x $(SOURCES) $(TESTS) scripts/docblocks

docs: ## Check that every function carries a full docblock
	./scripts/docblocks

check: lint docs test ## What CI runs

shell: ## A shell in the image
	$(RUN) --interactive --tty $(IMAGE) shell

install: ## Copy bin/ and lib/ to $(PREFIX)
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/lib
	cp -R src/bin/. $(DESTDIR)$(PREFIX)/bin/
	cp -R src/lib/. $(DESTDIR)$(PREFIX)/lib/
	find $(DESTDIR)$(PREFIX)/bin -type f -exec chmod 0755 {} +
	find $(DESTDIR)$(PREFIX)/lib -type f -exec chmod 0644 {} +

uninstall: ## Remove $(PREFIX)/bin and $(PREFIX)/lib
	rm -rf $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/lib

clean: ## Remove the coverage report
	rm -rf coverage

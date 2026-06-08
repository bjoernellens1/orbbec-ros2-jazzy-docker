IMAGE ?= ghcr.io/bjoernellens1/orbbec-ros2-jazzy:latest
COMPOSE ?= docker compose

.PHONY: build pull run list topics shell record udev clean

build:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) build

pull:
	docker pull $(IMAGE)

run:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) up femto-bolt

list:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile tools run --rm list-devices

topics:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile tools run --rm topics

shell:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile dev run --rm shell

record:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile record run --rm bag-record-rgbd

udev:
	ORBBEC_IMAGE=$(IMAGE) sudo -E ./scripts/install-host-udev-rules.sh

clean:
	$(COMPOSE) down --remove-orphans

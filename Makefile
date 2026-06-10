IMAGE ?= ghcr.io/bjoernellens1/orbbec-ros2-jazzy:latest
COMPOSE ?= docker compose

.PHONY: build pull run mega list topics shell record udev viewer doctor clean

build:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) build

pull:
	docker pull $(IMAGE)

run: ## Run the Femto Bolt ROS 2 publisher
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) up femto-bolt

mega: ## Run the Femto Mega ROS 2 publisher
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) up femto-mega

list:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile tools run --rm list-devices

topics:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile tools run --rm topics

shell:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile dev run --rm shell

record: ## Record training-ready aligned RGB-D topics from a Femto Bolt to ./bags
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile record run --rm bag-record-rgbd

record-mega: ## Record training-ready aligned RGB-D topics from a Femto Mega to ./bags
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile record run --rm bag-record-rgbd-mega

viewer:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile gui run --rm orbbecviewer

doctor:
	ORBBEC_IMAGE=$(IMAGE) $(COMPOSE) --profile tools run --rm doctor

udev:
	ORBBEC_IMAGE=$(IMAGE) sudo -E bash $(CURDIR)/scripts/install-host-udev-rules.sh

clean:
	$(COMPOSE) down --remove-orphans

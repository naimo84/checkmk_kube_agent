.DEFAULT_GOAL := help

define BROWSER_PYSCRIPT
import os, webbrowser, sys

from urllib.request import pathname2url

webbrowser.open("file://" + pathname2url(os.path.abspath(sys.argv[1])))
endef
export BROWSER_PYSCRIPT

define PRINT_HELP_PYSCRIPT
import re, sys

for line in sys.stdin:
	match = re.match(r'^([a-zA-Z_-]+):.*?## (.*)$$', line)
	if match:
		target, help = match.groups()
		print("%-20s %s" % (target, help))
endef
export PRINT_HELP_PYSCRIPT

PYTHON := python3
BROWSER := $(PYTHON) -c "$$BROWSER_PYSCRIPT"
PROJECT_NAME := checkmk_kube_agent
PROJECT_VERSION := $(shell $(PYTHON) -c "import src.${PROJECT_NAME};print(src.${PROJECT_NAME}.__version__)")
DOCKER_IMAGE_TAG := $(PROJECT_VERSION)
DOCKERHUB_PUBLISHER := checkmk
CLUSTER_COLLECTOR_IMAGE_NAME := checkmk-cluster-collector
CLUSTER_COLLECTOR_IMAGE := $(DOCKERHUB_PUBLISHER)/${CLUSTER_COLLECTOR_IMAGE_NAME}:${DOCKER_IMAGE_TAG}
NODE_COLLECTOR_IMAGE_NAME := checkmk-node-collector
NODE_COLLECTOR_IMAGE := $(DOCKERHUB_PUBLISHER)/${NODE_COLLECTOR_IMAGE_NAME}:${DOCKER_IMAGE_TAG}

.PHONY: help
help:
	@$(PYTHON) -c "$$PRINT_HELP_PYSCRIPT" < $(MAKEFILE_LIST)

.PHONY: clean
clean: clean-build clean-pyc clean-test ## remove all build, test, coverage and Python artifacts

.PHONY: clean-build
clean-build: ## remove build artifacts
	rm -fr build/
	rm -fr dist/
	rm -fr .eggs/
	find . -name '*.egg-info' -exec rm -fr {} +
	find . -name '*.egg' -exec rm -f {} +

.PHONY: clean-pyc
clean-pyc: ## remove Python file artifacts
	find . -name '*.pyc' -exec rm -f {} +
	find . -name '*.pyo' -exec rm -f {} +
	find . -name '*~' -exec rm -f {} +
	find . -name '__pycache__' -exec rm -fr {} +

.PHONY: clean-test
clean-test: ## remove test and coverage artifacts
	rm -fr .tox/
	rm -f .coverage
	rm -fr htmlcov/
	rm -fr .pytest_cache
	rm -fr .mypy_cache
	rm -fr .cache

coverage: ## check code coverage quickly with the default Python
	coverage run -m pytest --pyargs checkmk_kube_agent tests/unit
	coverage report -m
	coverage html
	$(BROWSER) htmlcov/index.html

.PHONY: dev-image
dev-image: dist ## build image to be used to run tests in a Docker container
	docker build --rm --target=dev --build-arg PACKAGE_VERSION="${PROJECT_VERSION}" -t $(CLUSTER_COLLECTOR_IMAGE_NAME)-dev -f docker/cluster_collector/Dockerfile .
	docker build --rm --target=dev --build-arg PACKAGE_VERSION="${PROJECT_VERSION}" -t $(NODE_COLLECTOR_IMAGE_NAME)-dev -f docker/node_collector/Dockerfile .

dist: clean ## builds source and wheel package
	$(PYTHON) setup.py sdist
	$(PYTHON) setup.py bdist_wheel
	ls -l dist

.PHONY: docs
docs: ## generate Sphinx HTML documentation, including API docs
	rm -f docs/checkmk_kube_agent.rst
	rm -f docs/modules.rst
	sphinx-apidoc -o docs/ src/checkmk_kube_agent
	$(MAKE) -C docs clean
	$(MAKE) -C docs html
	$(BROWSER) docs/_build/html/index.html

.PHONY: print-version
print-version: ## print project version
	@echo $(PROJECT_VERSION)

.PHONY: lint-docker
lint-docker: lint-dockerfile lint-docker-image ## check Dockerfiles and images

.PHONY: lint-dockerfile
lint-dockerfile: lint-dockerfile/hadolint-containerised ## check Dockerfile style

.PHONY: lint-dockerfile/hadolint
lint-dockerfile/hadolint: ## check Dockerfile style with Hadolint
	hadolint --failure-threshold warning --verbose docker/*/Dockerfile

.PHONY: lint-dockerfile/hadolint-containerised
lint-dockerfile/hadolint-containerised: ## check Dockerfile style with Hadolint
	./scripts/run-in-docker.sh \
		-i hadolint/hadolint:2.8.0-alpine \
		-c "hadolint --failure-threshold warning --verbose docker/*/Dockerfile"

.PHONY: lint-docker-image
lint-docker-image: lint-docker-image/trivy-containerised ## check vulnerability issues of Docker images with trivy

.PHONY: lint-docker-image/trivy
lint-docker-image/trivy: ## check vulnerability issues of Docker images with trivy
	trivy --cache-dir .cache image $(CLUSTER_COLLECTOR_IMAGE)
	trivy --cache-dir .cache image $(NODE_COLLECTOR_IMAGE)

.PHONY: lint-docker-image/trivy-containerised
lint-docker-image/trivy-containerised: release-image ## check vulnerability issues of Docker images with trivy
	./scripts/run-in-docker.sh \
		-i aquasec/trivy:0.21.2 \
		-o "-v /var/run/docker.sock:/var/run/docker.sock" \
		-o "--group-add=$$(getent group docker | cut -d: -f3)" \
		-c "trivy --cache-dir .cache image $(CLUSTER_COLLECTOR_IMAGE); \
			trivy --cache-dir .cache image $(NODE_COLLECTOR_IMAGE)"

.PHONY: lint-python
lint-python: lint-python/bandit lint-python/format lint-python/pylint ## check Python style

.PHONY: lint-python/bandit
lint-python/bandit: ## check for security issues with bandit
	bandit --configfile bandit.yaml --ini .bandit

.PHONY: lint-python/format
lint-python/format: ## check formatting with black and isort
	black --check src tests
	isort --check-only --diff src tests

.PHONY: lint-python/pylint
lint-python/pylint: ## check style with Pylint
	pylint --rcfile=.pylintrc src tests

.PHONY: lint-yaml
lint-yaml: lint-yaml/yamllint lint-yaml/kubeval-containerised ## check yaml style

.PHONY: lint-yaml/kubeval
lint-yaml/kubeval: ## check Kubernetes yaml with kubeval
	kubeval deploy/kubernetes/*

.PHONY: lint-yaml/kubeval-containerised
lint-yaml/kubeval-containerised: ## check Kubernetes yaml with kubeval
	./scripts/run-in-docker.sh \
		-i garethr/kubeval:0.15.0 \
		-c "kubeval deploy/kubernetes/*"

.PHONY: lint-yaml/yamllint
lint-yaml/yamllint: ## check yaml formatting with yamllint
	yamllint deploy/kubernetes

.PHONY: release-image
release-image: dist ## create the node and cluster collector Docker images
	docker build --rm --no-cache --build-arg PACKAGE_VERSION="${PROJECT_VERSION}" -t $(CLUSTER_COLLECTOR_IMAGE) -f docker/cluster_collector/Dockerfile .
	docker build --rm --no-cache --build-arg PACKAGE_VERSION="${PROJECT_VERSION}" -t $(NODE_COLLECTOR_IMAGE) -f docker/node_collector/Dockerfile .

.PHONY: servedocs
servedocs: docs ## compile the docs watching for changes
	watchmedo shell-command -p '*.rst' -c '$(MAKE) -C docs html' -R -D .

.PHONY: test-unit
test-unit: ## run unit tests and doctests quickly with the default Python
	coverage run -m pytest --doctest-modules --doctest-continue-on-failure --pyargs checkmk_kube_agent tests/unit
	coverage report -m --fail-under=100

.PHONY: typing-python
typing-python: typing-python/mypy ## check Python typing

.PHONY: typing-python/mypy
typing-python/mypy: ## check typing with mypy
	mypy src tests

.PHONY: gerrit-tests
gerrit-tests: release-image dev-image ## run all tests as Jenkins runs them on Gerrit commit
# NOTE: The make targets that are run by Jenkins are listed in the associated
# Jenkins script (full path below). They are retrieved with grep and run in
# sequence in the container which is also used by Jenkins. This is as close as we
# can get in terms of running this pipeline locally.
	for run_target_args in $(shell $(PYTHON) scripts/parse_jenkins_args.py); do \
		target=$$(echo $$run_target_args | cut -d, -f1); \
		docker_opts=$$(echo $$run_target_args | cut -d, -f2); \
		for image in $(CLUSTER_COLLECTOR_IMAGE_NAME) $(NODE_COLLECTOR_IMAGE_NAME); do \
			scripts/run-in-docker.sh \
        		-i $$image-dev:latest \
        		-o "$$docker_opts" \
        		-c "$(MAKE) $$target"; \
		done; \
	done

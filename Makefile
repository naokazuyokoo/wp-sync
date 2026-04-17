SHELL := /bin/bash
SCRIPT := ./sync.sh

.PHONY: help \
	pull-d push-d pull-t push-t pull-p push-p pull-u push-u pull-a push-a \
	pull-db push-db pull-theme push-theme pull-plugins push-plugins pull-upload push-upload pull-all push-all

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Main targets:"
	@echo "  pull-d / push-d    DB"
	@echo "  pull-t / push-t    Theme"
	@echo "  pull-p / push-p    Plugins"
	@echo "  pull-u / push-u    Uploads"
	@echo "  pull-a / push-a    All (DB + wp-content)"
	@echo ""
	@echo "Alias targets are also available: pull-db, push-all"
	@echo ""
	@echo "Optional: DRY_RUN=1 make pull-a"

pull-d:
	@bash $(SCRIPT) prod local db

push-d:
	@bash $(SCRIPT) local prod db

pull-t:
	@bash $(SCRIPT) prod local theme

push-t:
	@bash $(SCRIPT) local prod theme

pull-p:
	@bash $(SCRIPT) prod local plugins

push-p:
	@bash $(SCRIPT) local prod plugins

pull-u:
	@bash $(SCRIPT) prod local upload

push-u:
	@bash $(SCRIPT) local prod upload

pull-a:
	@bash $(SCRIPT) prod local all

push-a:
	@bash $(SCRIPT) local prod all

# aliases
pull-db: pull-d
push-db: push-d
pull-theme: pull-t
push-theme: push-t
pull-plugins: pull-p
push-plugins: push-p
pull-upload: pull-u
push-upload: push-u
pull-all: pull-a
push-all: push-a

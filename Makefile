PROJECT     := mpv-anki-clips
PREFIX      ?= /etc/mpv/
BRANCH      ?= remotes/origin/master
VERSION     := $(shell git describe --tags $(BRANCH))
RELEASE_DIR := .github/RELEASE
ZIP         := $(RELEASE_DIR)/$(PROJECT)_$(VERSION).zip
DOCS        := $(RELEASE_DIR)/README_$(VERSION).html
MD2HTML      = md2html --github --full-html

.PHONY: all clean docs install uninstall test test-config-gui

all: $(ZIP)
docs: $(DOCS)

test:
	lua tests/run.lua
	cargo test --locked --manifest-path config_gui/rust/Cargo.toml

test-config-gui:
	cargo test --locked --manifest-path config_gui/rust/Cargo.toml

$(ZIP):
	git archive \
	--prefix=$(PROJECT)_$(VERSION)/ \
	--format=zip \
	-o $@ \
	$(BRANCH) \

$(DOCS):
	git show "$(BRANCH):README.md" | $(MD2HTML) -o $@

install:
	cd src/mpv-anki-clips && find . -type f -iname '*.lua' | while read -r file; do \
		install -Dm644 "$$file" "$(PREFIX)/scripts/$(PROJECT)/$$file"; \
	done
	install -Dm644 src/mpv-anki-clips/exampleconfig/mpv-anki-clips-base.conf "$(PREFIX)/scripts/$(PROJECT)/exampleconfig/mpv-anki-clips-base.conf"
	install -Dm644 src/mpv-anki-clips/exampleconfig/mpv-anki-clips-core.conf "$(PREFIX)/scripts/$(PROJECT)/exampleconfig/mpv-anki-clips-core.conf"
	install -Dm644 src/mpv-anki-clips/exampleconfig/mpv-anki-clips-profiles.conf "$(PREFIX)/scripts/$(PROJECT)/exampleconfig/mpv-anki-clips-profiles.conf"
	install -Dm644 src/mpv-anki-clips/exampleconfig/mpv-anki-clips-base.conf "$(PREFIX)/script-opts/mpv-anki-clips-base.conf"
	install -Dm644 src/mpv-anki-clips/exampleconfig/mpv-anki-clips-core.conf "$(PREFIX)/script-opts/mpv-anki-clips-core.conf"

uninstall:
	rm -rf -- "$(PREFIX)/scripts/$(PROJECT)"
	rm -- "$(PREFIX)/script-opts/mpv-anki-clips-base.conf"
	rm -- "$(PREFIX)/script-opts/mpv-anki-clips-core.conf"

clean:
	rm -- $(ZIP) $(DOCS)

.PHONY: all fmt build check test docs servedocs

all: build

test:
	cargo nextest run --workspace
	cargo nextest run -p wezterm-escape-parser # no_std by default

check:
	cargo check --workspace
	cargo check -p wezterm-escape-parser
	cargo check -p wezterm-cell
	cargo check -p wezterm-surface
	cargo check -p wezterm-ssh

build:
	cargo build $(BUILD_OPTS)

fmt:
	cargo +nightly fmt

docs:
	ci/build-docs.sh

servedocs:
	ci/build-docs.sh serve

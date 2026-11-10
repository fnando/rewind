.PHONY: check fmt test build

fmt:
	cargo fmt

check:
	cargo fmt --check
	cargo clippy --quiet -- -Dwarnings -Dclippy::all -Dclippy::pedantic

test:
	cargo test --all

build:
	cargo build --release

#!/bin/sh

set -ex

FEATURES="bitcoin-hashes global-context lowmemory rand recovery serde std alloc bitcoin-hashes-std rand-std"

cargo --version
rustc --version

# Work out if we are using a nightly toolchain.
NIGHTLY=false
if cargo --version | grep nightly; then
    NIGHTLY=true
fi

# Pin dependencies as required if we are using MSRV toolchain.
if cargo --version | grep "1\.48"; then
    cargo update -p wasm-bindgen-test --precise 0.3.34
    cargo update -p serde --precise 1.0.156
fi

# Test if panic in C code aborts the process (either with a real panic or with SIGILL)
cargo test -- --ignored --exact 'tests::test_panic_raw_ctx_should_terminate_abnormally' 2>&1 | tee /dev/stderr | grep "SIGILL\\|panicked at '\[libsecp256k1\]"

# Make all cargo invocations verbose
export CARGO_TERM_VERBOSE=true

# Defaults / sanity checks
cargo build --all
cargo test --all

if [ "$DO_FEATURE_MATRIX" = true ]; then
    cargo build --all --no-default-features
    cargo test --all --no-default-features

    # All features
    cargo build --all --no-default-features --features="$FEATURES"
    cargo test --all --no-default-features --features="$FEATURES"
    # Single features
    for feature in ${FEATURES}
    do
        cargo build --all --no-default-features --features="$feature"
        cargo test --all --no-default-features --features="$feature"
    done
    # Features tested with 'std' feature enabled.
    for feature in ${FEATURES}
    do
        cargo build --all --no-default-features --features="std,$feature"
        cargo test --all --no-default-features --features="std,$feature"
    done
    # Other combos 
    RUSTFLAGS='--cfg=secp256k1_fuzz' RUSTDOCFLAGS='--cfg=secp256k1_fuzz' cargo test --all
    RUSTFLAGS='--cfg=secp256k1_fuzz' RUSTDOCFLAGS='--cfg=secp256k1_fuzz' cargo test --all --features="$FEATURES"
    cargo test --all --features="rand serde"

    if [ "$NIGHTLY" = true ]; then
        cargo test --all --all-features
        RUSTFLAGS='--cfg=secp256k1_fuzz' RUSTDOCFLAGS='--cfg=secp256k1_fuzz' cargo test --all --all-features
    fi

    # Examples
    cargo run --example sign_verify --features=bitcoin-hashes-std
    cargo run --example sign_verify_recovery --features=recovery,bitcoin-hashes-std
    cargo run --example generate_keys --features=rand-std
fi

if [ "$DO_LINT" = true ]
then
    cargo clippy --all-features --all-targets -- -D warnings
    cargo clippy --example sign_verify --features=bitcoin-hashes-std -- -D warnings
    cargo clippy --example sign_verify_recovery --features=recovery,bitcoin-hashes-std -- -D warnings
    cargo clippy --example generate_keys --features=rand-std -- -D warnings
fi

# Build the docs if told to (this only works with the nightly toolchain)
if [ "$DO_DOCSRS" = true ]; then
    RUSTDOCFLAGS="--cfg docsrs -D warnings -D rustdoc::broken-intra-doc-links" cargo +nightly doc --all-features
fi

# Build the docs with a stable toolchain, in unison with the DO_DOCSRS command
# above this checks that we feature guarded docs imports correctly.
if [ "$DO_DOCS" = true ]; then
    RUSTDOCFLAGS="-D warnings" cargo +stable doc --all-features
fi

# Webassembly stuff
if [ "$DO_WASM" = true ]; then
    clang --version
    CARGO_TARGET_DIR=wasm cargo install --force wasm-pack
    printf '\n[lib]\ncrate-type = ["cdylib", "rlib"]\n' >> Cargo.toml
    CC=clang wasm-pack build
    CC=clang wasm-pack test --node
fi

# Address Sanitizer
if [ "$DO_ASAN" = true ]; then
    clang --version
    cargo clean
    CC='clang -fsanitize=address -fno-omit-frame-pointer'                                        \
    RUSTFLAGS='-Zsanitizer=address -Clinker=clang -Cforce-frame-pointers=yes'                    \
    ASAN_OPTIONS='detect_leaks=1 detect_invalid_pointer_pairs=1 detect_stack_use_after_return=1' \
    cargo test --lib --all --features="$FEATURES" -Zbuild-std --target x86_64-unknown-linux-gnu
    cargo clean
    # The -Cllvm-args=-msan-eager-checks=0 flag was added to overcome this issue:
    # https://github.com/rust-bitcoin/rust-secp256k1/pull/573#issuecomment-1399465995
    CC='clang -fsanitize=memory -fno-omit-frame-pointer'                                                                        \
    RUSTFLAGS='-Zsanitizer=memory -Zsanitizer-memory-track-origins -Cforce-frame-pointers=yes -Cllvm-args=-msan-eager-checks=0' \
    cargo test --lib --all --features="$FEATURES" -Zbuild-std --target x86_64-unknown-linux-gnu
    cargo run --release --manifest-path=./no_std_test/Cargo.toml | grep -q "Verified Successfully"
    cargo run --release --features=alloc --manifest-path=./no_std_test/Cargo.toml | grep -q "Verified alloc Successfully"
fi

# Run formatter if told to.
if [ "$DO_FMT" = true ]; then
    if [ "$NIGHTLY" = false ]; then
        echo "DO_FMT requires a nightly toolchain (consider using RUSTUP_TOOLCHAIN)"
        exit 1
    fi
    rustup component add rustfmt
    cargo fmt --check || exit 1
fi

# Bench if told to, only works with non-stable toolchain (nightly, beta).
if [ "$DO_BENCH" = true ]
then
    RUSTFLAGS='--cfg=bench' cargo bench --features=recovery,rand-std
fi

exit 0

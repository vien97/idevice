# justfile (cải tiến)
# Mục tiêu: làm cho file dễ bảo trì, an toàn hơn khi chạy và thân thiện với CI.
set shell := ['bash', '-lc']

# Biến chung (thay đổi ở 1 chỗ)
FFI_DIR := 'ffi'
TOOLS_DIR := 'tools'
SWIFT_DIR := 'swift'
CPP_BUILD_DIR := 'cpp/examples/build'
FFI_BUILD_DIR := 'ffi/examples/build'

# Mặc định profile cho cargo. Gọi lại với ví dụ: just BUILD_PROFILE='--release' build-ffi-native
BUILD_PROFILE := '--release'

# Kiểm tra lệnh có tồn tại
check-cmd cmd:
  command -v {{cmd}} >/dev/null 2>&1 || { echo "Lệnh bắt buộc '{{cmd}}' không tìm thấy. Cài đặt nó rồi chạy lại."; exit 1; }

# Trợ giúp / danh sách recipe
help:
  @echo "Các recipe thường dùng:"
  @echo "  just check-features            - kiểm tra feature với cargo-hack"
  @echo "  just ci-check                  - lint, format, build cơ bản cho CI"
  @echo "  just build-ffi-native          - build crate ffi (dùng BUILD_PROFILE)"
  @echo "  just apple-build               - build xcframework (chỉ macOS)"
  @echo ""
  @echo "Ghi chú: override BUILD_PROFILE (mặc định '--release'), ví dụ:"
  @echo "  just BUILD_PROFILE='--release' apple-build"

# CI / kiểm tra feature
check-features:
  set -euo pipefail
  just check-cmd cargo
  just check-cmd cargo-hack
  cargo hack check -p idevice --each-feature --no-dev-deps \
    --features ring \
    --exclude-features aws-lc,openssl,rustcrypto,wasm,wasm-crypto
  cargo hack check -p idevice-ffi --each-feature --no-dev-deps \
    --features ring \
    --exclude-features aws-lc,openssl,rustcrypto

ci-check: build-ffi-native build-tools-native build-cpp build-c
  set -euo pipefail
  just check-cmd cargo
  cargo clippy --all-targets --all-features -- -D warnings
  cargo fmt -- --check

# Build FFI (trong thư mục ffi)
[working-directory: 'ffi']
build-ffi-native:
  set -euo pipefail
  just check-cmd cargo
  cargo build {{BUILD_PROFILE}}

# Build tools (trong thư mục tools)
[working-directory: 'tools']
build-tools-native:
  set -euo pipefail
  just check-cmd cargo
  cargo build {{BUILD_PROFILE}}

create-example-build-folder:
  mkdir -p {{CPP_BUILD_DIR}}
  mkdir -p {{FFI_BUILD_DIR}}

# Build C++ ví dụ
[working-directory: 'cpp/examples/build']
build-cpp: build-ffi-native create-example-build-folder
  set -euo pipefail
  just check-cmd cmake
  cmake -S .. -B . -DCMAKE_BUILD_TYPE=Release
  cmake --build . --config Release --parallel

# Build C ví dụ
[working-directory: 'ffi/examples/build']
build-c: build-ffi-native create-example-build-folder
  set -euo pipefail
  just check-cmd cmake
  cmake -S .. -B . -DCMAKE_BUILD_TYPE=Release
  cmake --build . --config Release --parallel

# Tạo xcframework (phụ thuộc apple-build)
xcframework: apple-build
  set -euo pipefail
  just check-cmd lipo
  just check-cmd xcodebuild
  rm -rf {{SWIFT_DIR}}/IDevice.xcframework
  rm -rf {{SWIFT_DIR}}/libs
  cp {{FFI_DIR}}/idevice.h {{SWIFT_DIR}}/include/idevice.h
  mkdir -p {{SWIFT_DIR}}/libs

  # kiểm tra đầu vào trước khi lipo
  test -f target/aarch64-apple-ios-sim/release/libidevice_ffi.a || { echo "Missing: target/aarch64-apple-ios-sim/release/libidevice_ffi.a"; exit 1; }
  test -f target/x86_64-apple-ios/release/libidevice_ffi.a || { echo "Missing: target/x86_64-apple-ios/release/libidevice_ffi.a"; exit 1; }

  lipo -create -output {{SWIFT_DIR}}/libs/idevice-ios-sim.a \
    target/aarch64-apple-ios-sim/release/libidevice_ffi.a \
    target/x86_64-apple-ios/release/libidevice_ffi.a

  # Lặp lại cho các arch khác (maccatalyst, macos)
  lipo -create -output {{SWIFT_DIR}}/libs/idevice-maccatalyst.a \
    target/aarch64-apple-ios-macabi/release/libidevice_ffi.a \
    target/x86_64-apple-ios-macabi/release/libidevice_ffi.a || true

  lipo -create -output {{SWIFT_DIR}}/libs/idevice-macos.a \
    target/aarch64-apple-darwin/release/libidevice_ffi.a \
    target/x86_64-apple-darwin/release/libidevice_ffi.a || true

  xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libidevice_ffi.a -headers {{SWIFT_DIR}}/include \
    -library {{SWIFT_DIR}}/libs/idevice-ios-sim.a -headers {{SWIFT_DIR}}/include \
    -library {{SWIFT_DIR}}/libs/idevice-macos.a -headers {{SWIFT_DIR}}/include \
    -library {{SWIFT_DIR}}/libs/idevice-maccatalyst.a -headers {{SWIFT_DIR}}/include \
    -output {{SWIFT_DIR}}/IDevice.xcframework

  zip -r {{SWIFT_DIR}}/bundle.zip {{SWIFT_DIR}}/IDevice.xcframework
  just check-cmd openssl
  openssl dgst -sha256 {{SWIFT_DIR}}/bundle.zip

# Apple-specific build: chỉ chạy trên macOS
[working-directory: 'ffi']
apple-build: # requires a Mac
  set -euo pipefail
  unameOut="$(uname -s)"
  if [ "$unameOut" != "Darwin" ]; then
    echo "apple-build chỉ chạy trên macOS. Vui lòng chạy trên Mac với Xcode."
    exit 1
  fi

  just check-cmd xcrun
  just check-cmd cargo

  # iOS device build
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build {{BUILD_PROFILE}} --target aarch64-apple-ios --features obfuscate

  # iOS Simulator (arm64)
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    cargo build {{BUILD_PROFILE}} --target aarch64-apple-ios-sim

  # iOS Simulator (x86_64)
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    cargo build {{BUILD_PROFILE}} --target x86_64-apple-ios

  # Mac Catalyst (arm64/x86_64) với ring vì aws-lc khó cho macabi
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk macosx --show-sdk-path)" \
    cargo build {{BUILD_PROFILE}} --target aarch64-apple-ios-macabi --no-default-features --features "ring full"
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk macosx --show-sdk-path)" \
    cargo build {{BUILD_PROFILE}} --target x86_64-apple-ios-macabi --no-default-features --features "ring full"

  # macOS native
  cargo build {{BUILD_PROFILE}} --target aarch64-apple-darwin
  cargo build {{BUILD_PROFILE}} --target x86_64-apple-darwin

SHELL := /bin/zsh

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
EXT := .so
else ifeq ($(UNAME_S),Darwin)
EXT := .dylib
else
$(error Unsupported OS $(UNAME_S). Supported: Darwin and Linux)
endif

empty :=
space := $(empty) $(empty)

ifeq ($(findstring $(space),$(CURDIR)),)
NGSPICE_BASE_DEFAULT := $(CURDIR)/third_party/ngspice
else
NGSPICE_BASE_DEFAULT := /tmp/autosage-ngspice
endif

NGSPICE_VERSION ?= 45.2
NGSPICE_SRC_ROOT ?= $(NGSPICE_BASE_DEFAULT)
NGSPICE_SRC_DIR ?= $(NGSPICE_SRC_ROOT)/ngspice-$(NGSPICE_VERSION)
NGSPICE_ARCHIVE ?= $(NGSPICE_SRC_ROOT)/ngspice-$(NGSPICE_VERSION).tar.gz
NGSPICE_DOWNLOAD_URL ?= https://sourceforge.net/projects/ngspice/files/ng-spice-rework/$(NGSPICE_VERSION)/ngspice-$(NGSPICE_VERSION).tar.gz/download
NGSPICE_PREFIX ?= $(NGSPICE_SRC_ROOT)/install

MFEM_DRIVER_BIN := Native/MFEMDriver/build/mfem-driver
TRUCK_FFI_LIB := Native/truck_ffi/target/release/libtruck_ffi$(EXT)
PMP_FFI_LIB := Native/pmp_ffi/build/libpmp_ffi$(EXT)
QUARTET_FFI_LIB := Native/quartet_ffi/build/libquartet_ffi$(EXT)
VTK_FFI_LIB := Native/vtk_ffi/build/libvtk_ffi$(EXT)
OPEN3D_FFI_LIB := Native/open3d_ffi/build/libopen3d_ffi$(EXT)
NGSPICE_SHARED_LIB := $(NGSPICE_PREFIX)/lib/libngspice$(EXT)
NGSPICE_FFI_LIB := Native/ngspice_ffi/build/libngspice_ffi$(EXT)
NATIVE_LIB_DIR ?= Native/lib

.PHONY: lint format test run run-control build-mfem-driver build-truck-ffi build-pmp-ffi build-quartet-ffi build-vtk-ffi build-open3d-ffi build-ngspice-shared build-ngspice-ffi install-native-libs clean-native

lint:
	@if command -v swift-format >/dev/null 2>&1; then \
		swift-format lint -r Sources Tests; \
	else \
		echo "swift-format not installed; skipping lint."; \
	fi

format:
	@if command -v swift-format >/dev/null 2>&1; then \
		swift-format format -ir Sources Tests; \
	else \
		echo "swift-format not installed; skipping format."; \
	fi

test:
	swift test
	@if [ -x .venv/bin/pytest ]; then \
		PYTHONPATH=. .venv/bin/pytest -q; \
	else \
		echo ".venv/bin/pytest not found; skipping Python tests."; \
	fi

run:
	swift run AutoSageServer

run-control:
	swift run AutoSageControl

build-mfem-driver:
	cmake -S Native/MFEMDriver -B Native/MFEMDriver/build
	cmake --build Native/MFEMDriver/build -j
	@echo "MFEM driver: $(MFEM_DRIVER_BIN)"

build-truck-ffi:
	@if ! command -v cargo >/dev/null 2>&1; then \
		echo "cargo not installed; cannot build Native/truck_ffi."; \
		exit 1; \
	fi
	@if ! command -v cbindgen >/dev/null 2>&1; then \
		echo "cbindgen not installed; install with: cargo install cbindgen"; \
		exit 1; \
	fi
	cargo build --manifest-path Native/truck_ffi/Cargo.toml --release
	@echo "Truck FFI library: $(TRUCK_FFI_LIB)"

build-pmp-ffi:
	cmake -S Native/pmp_ffi -B Native/pmp_ffi/build
	cmake --build Native/pmp_ffi/build -j
	@echo "PMP FFI library: $(PMP_FFI_LIB)"

build-quartet-ffi:
	cmake -S Native/quartet_ffi -B Native/quartet_ffi/build
	cmake --build Native/quartet_ffi/build -j
	@echo "Quartet FFI library: $(QUARTET_FFI_LIB)"

build-vtk-ffi:
	cmake -S Native/vtk_ffi -B Native/vtk_ffi/build
	cmake --build Native/vtk_ffi/build -j
	@echo "VTK FFI library: $(VTK_FFI_LIB)"

build-open3d-ffi:
	cmake -S Native/open3d_ffi -B Native/open3d_ffi/build
	cmake --build Native/open3d_ffi/build -j
	@echo "Open3D FFI library: $(OPEN3D_FFI_LIB)"

build-ngspice-shared:
	@set -euo pipefail; \
	mkdir -p "$(NGSPICE_SRC_ROOT)"; \
	if [ ! -d "$(NGSPICE_SRC_DIR)" ]; then \
		if [ ! -f "$(NGSPICE_ARCHIVE)" ]; then \
			echo "Downloading ngspice $(NGSPICE_VERSION) from $(NGSPICE_DOWNLOAD_URL)"; \
			curl -L "$(NGSPICE_DOWNLOAD_URL)" -o "$(NGSPICE_ARCHIVE)"; \
		fi; \
		tar -xzf "$(NGSPICE_ARCHIVE)" -C "$(NGSPICE_SRC_ROOT)"; \
	fi; \
	cd "$(NGSPICE_SRC_DIR)"; \
	./configure --prefix="$(NGSPICE_PREFIX)" --with-ngshared --disable-debug --disable-maintainer-mode --disable-openmp; \
	$(MAKE) -j; \
	$(MAKE) install
	@echo "ngspice shared library: $(NGSPICE_SHARED_LIB)"

build-ngspice-ffi:
	cmake -S Native/ngspice_ffi -B Native/ngspice_ffi/build -DNGSPICE_ROOT="$(NGSPICE_PREFIX)"
	cmake --build Native/ngspice_ffi/build -j
	@echo "ngspice FFI library: $(NGSPICE_FFI_LIB)"

install-native-libs:
	@set -euo pipefail; \
	mkdir -p "$(NATIVE_LIB_DIR)"; \
	for lib in "$(TRUCK_FFI_LIB)" "$(PMP_FFI_LIB)" "$(QUARTET_FFI_LIB)" "$(VTK_FFI_LIB)" "$(OPEN3D_FFI_LIB)" "$(NGSPICE_FFI_LIB)"; do \
		if [ -f "$$lib" ]; then \
			cp -f "$$lib" "$(NATIVE_LIB_DIR)/"; \
			echo "Installed $$lib -> $(NATIVE_LIB_DIR)"; \
		else \
			echo "Skipping missing library: $$lib"; \
		fi; \
	done

clean-native:
	rm -rf Native/MFEMDriver/build Native/pmp_ffi/build Native/quartet_ffi/build Native/vtk_ffi/build Native/open3d_ffi/build Native/ngspice_ffi/build
	rm -rf Native/truck_ffi/target
	rm -rf "$(NATIVE_LIB_DIR)"

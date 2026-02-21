# ngspice_ffi

`ngspice_ffi` is a narrow C ABI wrapper around ngspice shared library mode.
It exposes two functions for AutoSage:

- `ngspice_run_netlist(...)`
- `ngspice_free_result(...)`

## Build requirements

1. Build/install ngspice with shared mode enabled:

```bash
./configure --with-ngshared --prefix=/path/to/ngspice-install
make -j
make install
```

2. Build this wrapper:

```bash
cmake -S Native/ngspice_ffi -B Native/ngspice_ffi/build -DNGSPICE_ROOT=/path/to/ngspice-install
cmake --build Native/ngspice_ffi/build -j
```

This produces `libngspice_ffi.dylib` (macOS) or `libngspice_ffi.so` (Linux).

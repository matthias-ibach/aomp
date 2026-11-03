#!/bin/bash
#
# run_ectrans.sh:
#   Build ecTrans (ECMWF spectral transform library) for the GPU with the
#   AOMP OpenMP-offload toolchain (amdclang, amdflang), then run the ecTrans
#   benchmark in single and double precision and check its round-trip errors.
#
# The ecTrans sources are cloned into $AOMP_REPOS_TEST by clone_test.sh
# (see manifests/test_<version>.xml). Source repo:
#   https://github.com/ecmwf-ifs/ectrans     (branch develop)
#
# ecTrans requires ecbuild, fiat and LAPACK. Build the AOMP supplemental
# dependencies first with:
#   ./build_supp.sh fiat lapack
#
# The GPU build also needs hipBLAS, hipFFT, rocBLAS and rocFFT. They are
# searched below $AOMP, $ROCM_PATH and /opt/rocm (get_cmake_module_path), or
# only below $ECTRANS_ROCM_LIBS if that is set. HIP comes from the ROCm of
# the compiler under test ($ROCM_PATH).
#
# The benchmark runs ECTRANS_BENCH_NITER round trips (inverse + direct
# transform) at truncation ECTRANS_BENCH_TRUNC and fails if one of its four
# errors is not a number or larger than ECTRANS_BENCH_MAXERR_SP /
# ECTRANS_BENCH_MAXERR_DP. Timings are printed, not checked.
# Set ECTRANS_CTEST=ON to also build and run the upstream CTest suite (131
# tests, about 3-4 min), ECTRANS_BENCHMARK=OFF to skip the benchmark.
#
# Usage:
#   ./run_ectrans.sh          configure + build ecTrans + run benchmark (+ CTest)
#   ./run_ectrans.sh nocmake  skip CMake configure, rebuild + benchmark (+ CTest)
#   ./run_ectrans.sh rerun    skip build, just re-run benchmark (+ CTest)
#

# --- Start standard header to set AOMP environment variables ----
realpath=$(realpath "$0")
thisdir=$(dirname "$realpath")
export AOMP_USE_CCACHE=0

# shellcheck disable=SC1091
. "$thisdir"/aomp_common_vars
# --- end standard header ----

# Offload kernel tracing is very noisy across a full test-suite; default off.
export LIBOMPTARGET_KERNEL_TRACE=${LIBOMPTARGET_KERNEL_TRACE:-0}

# Fail instead of silently falling back to the host if offloading does not work.
export OMP_TARGET_OFFLOAD=${OMP_TARGET_OFFLOAD:-MANDATORY}

# Setup AOMP variables
AOMP=${AOMP:-$HOME/rocm/srock/llvm}

# Use function to set and test AOMP_GPU
setaompgpu

# --- ecTrans specific variables (all overridable from the environment) -----

# Directory name the ecTrans repo is cloned into (matches manifest path=).
AOMP_ECTRANS_REPO_NAME=${AOMP_ECTRANS_REPO_NAME:-ectrans}
ECTRANS_REPO=${ECTRANS_REPO:-$AOMP_REPOS_TEST/$AOMP_ECTRANS_REPO_NAME}
ECTRANS_BUILD=${ECTRANS_BUILD:-$ECTRANS_REPO/build-aomp-$AOMP_GPU}

# GPU arch for the offload and HIP code. Defaults to detected AOMP_GPU.
GPU_ARCH=${GPU_ARCH:-$AOMP_GPU}

# Supplemental components built by build_supp.sh.
ECBUILD_INSTALL=${ECBUILD_INSTALL:-$AOMP_SUPP/ecbuild}
FIAT_INSTALL=${FIAT_INSTALL:-$AOMP_SUPP/fiat}
LAPACK_INSTALL=${LAPACK_INSTALL:-$AOMP_SUPP/lapack}

# ROCm of the compiler under test (HIP headers, runtime and CMake config).
# For a ROCm install $AOMP is <rocm>/lib/llvm, for AOMP builds <root>/llvm.
if [ -z "$ROCM_PATH" ]; then
  for dir in "$AOMP" "$AOMP/.." "$AOMP/../.."; do
    if [ -d "$dir/include/hip" ]; then
      ROCM_PATH=$(realpath "$dir")
      break
    fi
  done
fi
if [ -z "$ROCM_PATH" ] || [ ! -d "$ROCM_PATH/include/hip" ]; then
  echo "ERROR: no HIP headers found for AOMP=$AOMP, set ROCM_PATH."
  exit 1
fi

# Compiler flags. The offload flags go into OpenMP_Fortran_FLAGS (every
# OpenMP target is compiled for the GPU, including benchmark. Applying only
# (ECTRANS_OMP_OFFLOAD_FLAGS) gives wrong benchmark result.
ECTRANS_Fortran_FLAGS=${ECTRANS_Fortran_FLAGS:-"-O3"}
ECTRANS_OpenMP_FLAGS=${ECTRANS_OpenMP_FLAGS:-"-fopenmp --offload-arch=$GPU_ARCH"}
ECTRANS_LINKER_FLAGS=${ECTRANS_LINKER_FLAGS:-"-fopenmp --offload-arch=$GPU_ARCH -lstdc++"}

# Graph-based optimization of the GEMM and FFT kernels (ecTrans default ON).
ECTRANS_GPU_GRAPHS=${ECTRANS_GPU_GRAPHS:-ON}

# Keeping the at run time compiled rocFFT kernels for all tests of a run
export ROCFFT_RTC_CACHE_PATH=${ROCFFT_RTC_CACHE_PATH:-$ECTRANS_BUILD/rocfft_kernel_cache.db}

# Upstream CTest suite (off by default, the benchmark is the nightly test).
ECTRANS_CTEST=${ECTRANS_CTEST:-OFF}

# Benchmark: size and allowed round-trip error for all four errors.
ECTRANS_BENCHMARK=${ECTRANS_BENCHMARK:-ON}
ECTRANS_BENCH_DIR=${ECTRANS_BENCH_DIR:-$ECTRANS_BUILD/benchmark}
ECTRANS_BENCH_TRUNC=${ECTRANS_BENCH_TRUNC:-159}
ECTRANS_BENCH_NITER=${ECTRANS_BENCH_NITER:-20}
ECTRANS_BENCH_MAXERR_SP=${ECTRANS_BENCH_MAXERR_SP:-1e-5}
ECTRANS_BENCH_MAXERR_DP=${ECTRANS_BENCH_MAXERR_DP:-1e-12}

# Make the AOMP compilers and supplemental libraries visible to CMake and tests.
export PATH=$AOMP/bin:$ROCM_PATH/bin:$PATH
export LD_LIBRARY_PATH=$AOMP/lib:$ROCM_PATH/lib:$LD_LIBRARY_PATH
export LIBRARY_PATH=$AOMP/lib:$ROCM_PATH/lib:$LIBRARY_PATH

AOMP_CMAKE=${AOMP_CMAKE:-cmake}
AOMP_CTEST=${AOMP_CTEST:-"$(dirname "$AOMP_CMAKE")/ctest"}
ECTRANS_CTEST_ARGS=${ECTRANS_CTEST_ARGS:-"--output-on-failure"}

if [ ! -d "$ECTRANS_REPO" ]; then
  echo "ERROR: ecTrans sources not found at $ECTRANS_REPO"
  echo "       Run clone_test.sh first (needs a manifest entry for ectrans)."
  exit 1
fi

if [ ! -d "$ECBUILD_INSTALL" ] || [ ! -d "$FIAT_INSTALL" ] || [ ! -d "$LAPACK_INSTALL" ]; then
  echo "ERROR: ecbuild, fiat or lapack not found at $ECBUILD_INSTALL, $FIAT_INSTALL, $LAPACK_INSTALL"
  echo "       Build AOMP supplemental components first with build_supp.sh fiat lapack,"
  echo "       or set ECBUILD_INSTALL, FIAT_INSTALL and LAPACK_INSTALL."
  exit 1
fi

# Find the ROCm math libraries.
cmake_prefix_path="$LAPACK_INSTALL;$ROCM_PATH"
declare -A seen_prefix=()
for package in hip hipblas hipfft rocblas rocfft; do
  if [ -n "$ECTRANS_ROCM_LIBS" ] && [ "$package" != "hip" ]; then
    package_cmake_dir=$(get_cmake_module_path "$package" "$ECTRANS_ROCM_LIBS")
  else
    package_cmake_dir=$(get_cmake_module_path "$package")
  fi
  if [ -z "$package_cmake_dir" ]; then
    echo "ERROR: no CMake package '$package' below ${ECTRANS_ROCM_LIBS:-$AOMP, $ROCM_PATH or /opt/rocm}"
    exit 1
  fi
  package_root=$(realpath "${package_cmake_dir%/lib/cmake}")
  if [ "$package_root" == "$ROCM_PATH" ] || [ -n "${seen_prefix[$package_root]:-}" ]; then
    continue
  fi
  if [ "$package" == "hip" ]; then
    echo "WARNING: HIP is taken from $package_root, not from $ROCM_PATH"
  fi
  seen_prefix["$package_root"]=1
  cmake_prefix_path+=";$package_root"
  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$package_root/lib
done
unset seen_prefix

ulimit -s unlimited

run_ectrans_ctest() {

  echo "=== ecTrans test configuration ==="
  echo "Repo:         $ECTRANS_REPO"
  echo "Build:        $ECTRANS_BUILD"
  echo "fiat:         $FIAT_INSTALL"
  echo "GPU arch:     $GPU_ARCH"
  echo "ROCm (HIP):   $ROCM_PATH"
  echo "Prefix path:  $cmake_prefix_path"
  echo "CTest args:   $ECTRANS_CTEST_ARGS"
  echo "=== End ecTrans test configuration ==="

  # shellcheck disable=SC2086
  "$AOMP_CTEST" --test-dir "$ECTRANS_BUILD" $ECTRANS_CTEST_ARGS
  ret=$?

  if [ "$ret" -ne 0 ]; then
    echo "ectrans" >> "$ECTRANS_REPO"/failing-tests.txt
  else
    echo "ectrans" >> "$ECTRANS_REPO"/passing-tests.txt
  fi
  return "$ret"
}

# Run the GPU benchmark for one precision and check its four round-trip errors.
run_ectrans_benchmark() {
  local prec=$1 maxerr=$2
  local exe=$ECTRANS_BUILD/bin/ectrans-benchmark-gpu-$prec
  local log=$ECTRANS_BENCH_DIR/benchmark-$prec.log

  echo "=== ecTrans benchmark $prec: T$ECTRANS_BENCH_TRUNC, $ECTRANS_BENCH_NITER iterations, allowed error $maxerr ==="
  mkdir -p "$ECTRANS_BENCH_DIR"
  cd "$ECTRANS_BENCH_DIR" || exit 1

  OMP_NUM_THREADS=${OMP_NUM_THREADS:-1} \
  LIBOMPTARGET_AMDGPU_TEAMS_PER_CU=${LIBOMPTARGET_AMDGPU_TEAMS_PER_CU:-4} \
    "$exe" --truncation "$ECTRANS_BENCH_TRUNC" --niter "$ECTRANS_BENCH_NITER" \
    --norms --scders --uvders --nlev 137 --nfld 1 --keep-pgp-arrays-on-device \
    > "$log" 2>&1
  ret=$?

  grep -E "^max error" "$log"
  if [ "$ret" -eq 0 ]; then
    # Fail if one of the four errors is missing, NaN, Infinity or larger than the allowed error.
    awk -v limit="$maxerr" '
      /^max error zsp/ {
        n++
        if ($NF !~ /^-?[0-9]*\.[0-9]+E[-+][0-9]+$/ || $NF + 0 > limit + 0) {
          print "Error " $NF " in \"" $0 "\" is not below " limit
          bad++
        }
      }
      END { if (n != 4) print "Expected 4 errors, found " n; exit (n != 4 || bad > 0) }' "$log"
    ret=$?
  fi
  echo "Inverse-direct transforms $(grep -A2 "Inverse-direct transforms" "$log" | grep "avg")"

  if [ "$ret" -ne 0 ]; then
    echo "ecTrans benchmark $prec FAILED, see $log"
    echo "ectrans-benchmark-$prec" >> "$ECTRANS_REPO"/failing-tests.txt
  else
    echo "ectrans-benchmark-$prec" >> "$ECTRANS_REPO"/passing-tests.txt
  fi
  return "$ret"
}

run_ectrans_tests() {
  local status=0
  if [ "$ECTRANS_CTEST" == "ON" ]; then
    run_ectrans_ctest || status=1
  fi
  if [ "$ECTRANS_BENCHMARK" == "ON" ]; then
    run_ectrans_benchmark sp "$ECTRANS_BENCH_MAXERR_SP" || status=1
    run_ectrans_benchmark dp "$ECTRANS_BENCH_MAXERR_DP" || status=1
  fi
  return "$status"
}

if [ "$1" == "rerun" ]; then
  cd "$ECTRANS_REPO" || exit 1
  rm -f failing-tests.txt passing-tests.txt
  run_ectrans_tests
  exit $?
fi

cd "$ECTRANS_REPO" || exit 1
rm -f make-fail.txt failing-tests.txt passing-tests.txt

if [ "$1" != "nocmake" ]; then
  echo "Configuring ecTrans with AOMP OpenMP offload for $GPU_ARCH"
  rm -rf "$ECTRANS_BUILD"
  mkdir -p "$ECTRANS_BUILD"

  cmake_args=(
    -S "$ECTRANS_REPO"
    -B "$ECTRANS_BUILD"
    -Decbuild_ROOT="$ECBUILD_INSTALL"
    -Dfiat_ROOT="$FIAT_INSTALL"
    -DCMAKE_PREFIX_PATH="$cmake_prefix_path"
    -DLAPACK_LIBRARIES="$LAPACK_INSTALL/lib/liblapack.a;$LAPACK_INSTALL/lib/libblas.a"
    -DROCM_PATH="$ROCM_PATH"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER=amdclang
    -DCMAKE_CXX_COMPILER=amdclang++
    -DCMAKE_Fortran_COMPILER=amdflang
    -DCMAKE_HIP_COMPILER="$AOMP/bin/clang++"
    -DCMAKE_HIP_ARCHITECTURES="$GPU_ARCH"
    -DECBUILD_Fortran_FLAGS="$ECTRANS_Fortran_FLAGS"
    -DOpenMP_Fortran_FLAGS="$ECTRANS_OpenMP_FLAGS"
    -DCMAKE_EXE_LINKER_FLAGS="$ECTRANS_LINKER_FLAGS"
    -DBUILD_SHARED_LIBS=OFF
    -DENABLE_CPU=OFF
    -DENABLE_GPU=ON
    -DENABLE_GPU_STATIC=ON
    -DENABLE_OMP=ON
    -DENABLE_ACC=OFF
    -DENABLE_MPI=OFF
    -DENABLE_GPU_AWARE_MPI=OFF
    -DENABLE_ROCFFT=ON
    -DENABLE_GPU_GRAPHS_GEMM="$ECTRANS_GPU_GRAPHS"
    -DENABLE_GPU_GRAPHS_FFT="$ECTRANS_GPU_GRAPHS"
    -DENABLE_SINGLE_PRECISION=ON
    -DENABLE_DOUBLE_PRECISION=ON
    -DENABLE_TESTS="$ECTRANS_CTEST"
  )
  # Keep the HIP headers of the compiler under test ahead of a borrowed ROCm.
  add_cmake_rocm_header_priority_args cmake_args "$ROCM_PATH"

  echo "$AOMP_CMAKE ${cmake_args[*]}"
  "$AOMP_CMAKE" "${cmake_args[@]}"
  ret=$?
  if [ "$ret" -ne 0 ]; then
    echo "ectrans-configure" >> make-fail.txt
    exit 1
  fi
  if ! check_cmake_rocm_header_priority "$ECTRANS_BUILD" "$ROCM_PATH"; then
    echo "ectrans-configure" >> make-fail.txt
    exit 1
  fi
fi

echo "Building ecTrans"
"$AOMP_CMAKE" --build "$ECTRANS_BUILD" -j"$AOMP_JOB_THREADS"
ret=$?
if [ "$ret" -ne 0 ]; then
  echo "ectrans" >> make-fail.txt
  exit 1
fi

run_ectrans_tests
exit $?

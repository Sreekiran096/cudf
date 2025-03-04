# Copyright (c) 2019-2022, NVIDIA CORPORATION.

import os
import re
import shutil

from setuptools import find_packages, setup

import versioneer

install_requires = [
    "cudf",
    "dask>=2022.03.0",
    "distributed>=2022.03.0",
    "fsspec>=0.6.0",
    "numpy",
    "pandas>=1.0,<1.5.0dev0",
]

extras_require = {
    "test": [
        "numpy",
        "pandas>=1.0,<1.5.0dev0",
        "pytest",
        "numba>=0.53.1",
        "dask>=2021.09.1",
        "distributed>=2021.09.1",
    ]
}


def get_cuda_version_from_header(cuda_include_dir, delimeter=""):

    cuda_version = None

    with open(os.path.join(cuda_include_dir, "cuda.h"), encoding="utf-8") as f:
        for line in f.readlines():
            if re.search(r"#define CUDA_VERSION ", line) is not None:
                cuda_version = line
                break

    if cuda_version is None:
        raise TypeError("CUDA_VERSION not found in cuda.h")
    cuda_version = int(cuda_version.split()[2])
    return "%d%s%d" % (
        cuda_version // 1000,
        delimeter,
        (cuda_version % 1000) // 10,
    )


CUDA_HOME = os.environ.get("CUDA_HOME", False)
if not CUDA_HOME:
    path_to_cuda_gdb = shutil.which("cuda-gdb")
    if path_to_cuda_gdb is None:
        raise OSError(
            "Could not locate CUDA. "
            "Please set the environment variable "
            "CUDA_HOME to the path to the CUDA installation "
            "and try again."
        )
    CUDA_HOME = os.path.dirname(os.path.dirname(path_to_cuda_gdb))

if not os.path.isdir(CUDA_HOME):
    raise OSError(f"Invalid CUDA_HOME: directory does not exist: {CUDA_HOME}")

cuda_include_dir = os.path.join(CUDA_HOME, "include")
cupy_package_name = "cupy-cuda" + get_cuda_version_from_header(
    cuda_include_dir
)
install_requires.append(cupy_package_name)


setup(
    name="dask-cudf",
    version=versioneer.get_version(),
    description="Utilities for Dask and cuDF interactions",
    url="https://github.com/rapidsai/cudf",
    author="NVIDIA Corporation",
    license="Apache 2.0",
    classifiers=[
        "Intended Audience :: Developers",
        "Topic :: Database",
        "Topic :: Scientific/Engineering",
        "License :: OSI Approved :: Apache Software License",
        "Programming Language :: Python",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
    ],
    packages=find_packages(exclude=["tests", "tests.*"]),
    cmdclass=versioneer.get_cmdclass(),
    install_requires=install_requires,
    extras_require=extras_require,
)

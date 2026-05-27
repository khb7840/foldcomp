#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO_ROOT"

cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target foldcomp

./test/run_smoke.sh ./build/foldcomp

python -m pip uninstall -y foldcomp >/dev/null 2>&1 || true
python -m pip install ".[test]"

REPO_ROOT="$REPO_ROOT" python - <<'PY'
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()

cleaned_paths = []
for entry in sys.path:
    resolved = Path(entry or ".").resolve()
    if resolved == repo_root:
        continue
    cleaned_paths.append(entry)

sys.path = cleaned_paths

spec = importlib.util.spec_from_file_location(
    "foldcomp_pytests", repo_root / "test" / "test_foldcomp.py"
)
if spec is None or spec.loader is None:
    raise RuntimeError("Failed to load python API tests")

module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PytestConfig:
    def __init__(self, rootpath: Path) -> None:
        self.rootpath = rootpath

pytestconfig = PytestConfig(repo_root)

module.test_decompress(pytestconfig)
module.test_open_db_all(pytestconfig)
module.test_open_db_ids(pytestconfig)
module.test_open_db_str(pytestconfig)
PY

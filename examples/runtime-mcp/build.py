"""Build .build/server.zip: the MCP server plus its dependencies for AgentCore Runtime (Linux, ARM64, Python 3.13).

Run from this folder:  python build.py
Needs Python and uv (https://docs.astral.sh/uv/), no Docker. uv is used because it installs for the Runtime's
platform (Linux, ARM64) from any computer, including Windows; plain pip would pick Windows-only packages.
"""

import pathlib
import shutil
import subprocess
import zipfile

here = pathlib.Path(__file__).resolve().parent
build = here / ".build"
package = build / "package"

shutil.rmtree(build, ignore_errors=True)
package.mkdir(parents=True)

subprocess.run(
    [
        "uv", "pip", "install",
        "--requirement", str(here / "server" / "requirements.txt"),
        "--target", str(package),
        "--python-platform", "aarch64-manylinux2014",
        "--python-version", "3.13",
        "--only-binary", ":all:",
        "--quiet",
    ],
    check=True,
)
shutil.copy(here / "server" / "main.py", package / "main.py")

out = build / "server.zip"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for path in sorted(package.rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            zf.write(path, path.relative_to(package).as_posix())
print(f"built {out} ({out.stat().st_size / 1_000_000:.1f} MB)")

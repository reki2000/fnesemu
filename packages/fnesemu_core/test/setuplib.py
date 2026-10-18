"""Helpers for the setup.py scripts under test/cpu and test/roms.

Each setup.py prepares its data in a .build/ directory next to itself.
A setup.py exits with 0 when the data is ready and with a non-zero code
when it cannot prepare the data; the callers skip the test in that case.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path


class SetupError(Exception):
    pass


def build_dir(script: str) -> Path:
    """Returns the .build/ directory next to the given setup.py."""
    d = Path(script).resolve().parent / ".build"
    d.mkdir(exist_ok=True)
    return d


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _verify(path: Path, digest: str):
    actual = sha256(path)
    if actual != digest:
        raise SetupError(f"sha256 mismatch for {path.name}: {actual}")


def download(url: str, dest: Path, digest: str) -> Path:
    """Downloads url to dest unless dest already has the given sha256."""
    if dest.exists() and sha256(dest) == digest:
        return dest
    tmp = dest.with_name(dest.name + ".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as r, tmp.open("wb") as f:
            shutil.copyfileobj(r, f)
    except OSError as e:
        tmp.unlink(missing_ok=True)
        raise SetupError(f"cannot download {url}: {e}") from e
    _verify(tmp, digest)
    tmp.replace(dest)
    return dest


def extract_tar(archive: Path, members: dict[str, Path]):
    """Extracts the archive members (name -> destination) from a tarball."""
    with tarfile.open(archive) as t:
        for name, dest in members.items():
            f = t.extractfile(name)
            if f is None:
                raise SetupError(f"{name} is not a file in {archive.name}")
            dest.write_bytes(f.read())


def extract_zip(archive: Path, members: dict[str, Path]):
    """Extracts the archive members (name -> destination) from a zip file."""
    import zipfile

    with zipfile.ZipFile(archive) as z:
        for name, dest in members.items():
            try:
                dest.write_bytes(z.read(name))
            except KeyError as e:
                raise SetupError(f"{name} is not in {archive.name}") from e


def git_checkout(url: str, commit: str, dest: Path, sparse: list[str] | None = None,
                 submodules: bool = False) -> Path:
    """Checks out one commit of a repository into dest, optionally sparse or with its submodules."""
    stamp = dest / ".fnesemu-commit"
    key = "\n".join([commit, *(sparse or [])]) + "\n"
    if stamp.exists() and stamp.read_text() == key:
        return dest
    if shutil.which("git") is None:
        raise SetupError("git is not installed")
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)

    def git(*args):
        r = subprocess.run(["git", "-C", str(dest), *args], capture_output=True, text=True)
        if r.returncode != 0:
            raise SetupError(f"git {' '.join(args)} failed: {r.stderr.strip()}")

    git("init", "-q")
    git("remote", "add", "origin", url)
    if sparse:
        git("sparse-checkout", "set", "--no-cone", *sparse)
    git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", commit)
    git("checkout", "-q", "FETCH_HEAD")
    if submodules:
        git("submodule", "update", "-q", "--init", "--recursive", "--depth", "1")
    stamp.write_text(key)
    return dest


DOCKERFILE = Path(__file__).resolve().parent / "docker" / "Dockerfile"


def _docker_image() -> str:
    """Builds the toolchain image once per Dockerfile revision and returns its tag."""
    tag = "fnesemu-testroms:" + sha256(DOCKERFILE)[:12]
    if subprocess.run(["docker", "image", "inspect", tag], capture_output=True).returncode != 0:
        print(f"building the docker image {tag}...", file=sys.stderr)
        r = subprocess.run(["docker", "build", "-q", "-t", tag, str(DOCKERFILE.parent)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SetupError(f"docker build failed: {r.stderr.strip()[-800:]}")
    return tag


def toolchain(cmd: list[str], cwd: Path, tools: list[str]):
    """Runs a build command with the host tools, or inside the toolchain image when one is missing.

    The command sees only the .build/ directory that contains cwd. Set FNESEMU_SETUP_DOCKER=1 to always use the image.
    """
    on_host = os.environ.get("FNESEMU_SETUP_DOCKER") != "1" and all(shutil.which(t) for t in tools)
    if on_host:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    else:
        if shutil.which("docker") is None:
            raise SetupError(f"needs {', '.join(tools)} or docker")
        root = next(p for p in [cwd, *cwd.parents] if p.name == ".build")
        r = subprocess.run(["docker", "run", "--rm", "-u", f"{os.getuid()}:{os.getgid()}",
                            "-v", f"{root}:/work", "-w", f"/work/{cwd.relative_to(root)}",
                            _docker_image(), *cmd], capture_output=True, text=True)
    if r.returncode != 0:
        raise SetupError(f"{' '.join(cmd)} failed: {(r.stdout + r.stderr).strip()[-800:]}")


def require_files(*paths: Path):
    for p in paths:
        if not p.exists():
            raise SetupError(f"{p} was not produced")


def run(setup):
    """Runs setup() and maps a failure to a non-zero exit code."""
    try:
        setup()
    except SetupError as e:
        print(f"setup failed: {e}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Build a RouterOS-importable Tailscale + BIRD image without Docker.

Alpine + tailscale/tailscaled + BIRD + the tailscale.sh entrypoint, assembled
from prebuilt pieces:
  - Alpine minirootfs (aarch64, armv7 or x86_64)
  - Alpine apk packages (iptables, iproute2, bird2 + deps), resolved from APKINDEX
  - official static Tailscale binaries from pkgs.tailscale.com
and written as a legacy `docker save` tar with *uncompressed* layers, which is
what RouterOS /container/add file=... can import.

Usage: build.py [--arch arm64|arm|amd64] [--tailscale 1.104.2] [--alpine 3.24] [-o FILE]
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import tarfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
ALPINE = "https://dl-cdn.alpinelinux.org/alpine"
PACKAGES = ["iptables", "ip6tables", "iproute2-minimal", "bird2"]


def fetch(url):
    os.makedirs(CACHE, exist_ok=True)
    # Key the cache on the full URL path (arch is in the path, not the filename),
    # so same-named apks for different arches (e.g. iptables-*.apk) don't collide.
    path = os.path.join(CACHE, url.split("://", 1)[-1].replace("/", "_"))
    if not os.path.exists(path):
        print("  fetch", url)
        with urllib.request.urlopen(url) as r, open(path + ".part", "wb") as f:
            f.write(r.read())
        os.replace(path + ".part", path)
    return path


def latest_versions(branch, alpine_arch):
    rel = urllib.request.urlopen(
        f"{ALPINE}/v{branch}/releases/{alpine_arch}/latest-releases.yaml").read().decode()
    rootfs = re.search(rf"file: (alpine-minirootfs-[\d.]+-{alpine_arch}\.tar\.gz)", rel).group(1)
    ts = json.load(urllib.request.urlopen("https://pkgs.tailscale.com/stable/?mode=json"))
    return rootfs, ts["TarballsVersion"]


def apk_index(branch, repo, alpine_arch):
    url = f"{ALPINE}/v{branch}/{repo}/{alpine_arch}/APKINDEX.tar.gz"
    with tarfile.open(fileobj=io.BytesIO(urllib.request.urlopen(url).read())) as t:
        text = t.extractfile("APKINDEX").read().decode()
    pkgs, provides = {}, {}
    for block in text.strip().split("\n\n"):
        f = {}
        for line in block.splitlines():
            k, _, v = line.partition(":")
            f.setdefault(k, v)
        p = {"name": f["P"], "ver": f["V"], "repo": repo,
             "deps": f.get("D", "").split(), "provides": f.get("p", "").split()}
        pkgs[p["name"]] = p
        for prov in p["provides"] + [p["name"]]:
            provides.setdefault(re.split(r"[=<>~]", prov)[0], p["name"])
    return pkgs, provides


def resolve(names, pkgs, provides, installed):
    """Return packages (dependency closure) not already in the base rootfs."""
    out, todo = [], list(names)
    while todo:
        dep = todo.pop()
        if dep.startswith("!"):
            continue
        dep = re.split(r"[=<>~]", dep)[0]
        name = provides.get(dep)
        if name is None:
            raise SystemExit(f"cannot resolve dependency {dep}")
        if name in installed or name in out:
            continue
        out.append(name)
        todo.extend(pkgs[name]["deps"])
    return out


def installed_pkgs(rootfs_tgz):
    with tarfile.open(rootfs_tgz) as t:
        db = t.extractfile("./lib/apk/db/installed").read().decode()
    names = set(re.findall(r"^P:(.+)$", db, re.M))
    for prov in re.findall(r"^p:(.+)$", db, re.M):
        names.update(re.split(r"[=<>~]", x)[0] for x in prov.split())
    return names


class Layer:
    """Uncompressed tar layer; later entries for the same path win."""

    def __init__(self):
        self.entries = {}

    def add(self, info, data=None):
        name = info.name.lstrip("./")
        if not name:
            return
        info.name = name
        info.uname = info.gname = ""
        self.entries[name] = (info, data)

    def add_tar(self, tf, skip=lambda n: False):
        for m in tf:
            if skip(m.name):
                continue
            data = tf.extractfile(m).read() if m.isfile() else None
            self.add(m, data)

    def add_file(self, name, data, mode=0o755):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mode, ti.mtime = len(data), mode, int(time.time())
        self.add(ti, data)

    def add_dir(self, name, mode=0o755):
        ti = tarfile.TarInfo(name)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, mode, int(time.time())
        self.add(ti)

    def bytes(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as t:
            for name in sorted(self.entries):
                info, data = self.entries[name]
                t.addfile(info, io.BytesIO(data) if data is not None else None)
        return buf.getvalue()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--alpine", default="3.24")
    ap.add_argument("--tailscale", help="default: latest stable")
    ap.add_argument("--arch", default="arm64", choices=["arm64", "arm", "amd64"])
    ap.add_argument("-o", "--output")
    ap.add_argument("--tag")
    a = ap.parse_args()

    # arm = 32-bit ARMv7 (RouterOS "arm"): Alpine armv7, Tailscale's arm build.
    alpine_arch, ts_arch, oci_arch, oci_variant = {
        "arm64": ("aarch64", "arm64", "arm64", None),
        "arm": ("armv7", "arm", "arm", "v7"),
        "amd64": ("x86_64", "amd64", "amd64", None),
    }[a.arch]
    if not a.output:
        a.output = os.path.join(HERE, f"tailscale-{a.arch}.tar")
    if not a.tag:
        a.tag = f"routeros-tailscale-bgp-{a.arch}:latest"

    rootfs_name, ts_latest = latest_versions(a.alpine, alpine_arch)
    ts_ver = a.tailscale or ts_latest
    print(f"Alpine {rootfs_name}, Tailscale {ts_ver}")

    rootfs = fetch(f"{ALPINE}/v{a.alpine}/releases/{alpine_arch}/{rootfs_name}")
    ts_tgz = fetch(f"https://pkgs.tailscale.com/stable/tailscale_{ts_ver}_{ts_arch}.tgz")

    # Layer 1: base OS + packages (what `FROM alpine` + `apk add` produce).
    pkgs, provides = {}, {}
    for repo in ("main", "community"):
        p, pv = apk_index(a.alpine, repo, alpine_arch)
        for k, v in p.items():
            pkgs.setdefault(k, v)
        for k, v in pv.items():
            provides.setdefault(k, v)
    extra = resolve(PACKAGES, pkgs, provides, installed_pkgs(rootfs))
    print("  packages:", " ".join(f"{n}-{pkgs[n]['ver']}" for n in sorted(extra)))

    base = Layer()
    with tarfile.open(rootfs) as t:
        base.add_tar(t)
    for n in extra:
        p = pkgs[n]
        apk = fetch(f"{ALPINE}/v{a.alpine}/{p['repo']}/{alpine_arch}/{n}-{p['ver']}.apk")
        # .apk = concatenated gzip streams (signature, control, data) of one tar.
        with open(apk, "rb") as f:
            raw = gzip.decompress(f.read())
        with tarfile.open(fileobj=io.BytesIO(raw), ignore_zeros=True) as t:
            base.add_tar(t, skip=lambda name: name.startswith("."))
    for d in ("dev/net", "run/tailscale", "var/cache/tailscale", "var/lib/tailscale"):
        base.add_dir(d)

    # Layer 2: tailscale binaries + entrypoint.
    app = Layer()
    for d in ("usr", "usr/local", "usr/local/bin"):
        app.add_dir(d)
    with tarfile.open(ts_tgz) as t:
        for m in t:
            b = m.name.rsplit("/", 1)[-1]
            if m.isfile() and b in ("tailscale", "tailscaled"):
                app.add_file(f"usr/local/bin/{b}", t.extractfile(m).read())
    with open(os.path.join(HERE, "tailscale.sh"), "rb") as f:
        app.add_file("usr/local/bin/tailscale.sh", f.read().replace(b"\r\n", b"\n"))

    layers = [base.bytes(), app.bytes()]
    diff_ids = ["sha256:" + hashlib.sha256(l).hexdigest() for l in layers]
    config = {
        "architecture": oci_arch, "os": "linux",
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "config": {
            "Env": ["PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"],
            "Cmd": ["/usr/local/bin/tailscale.sh"],
            "ExposedPorts": {"41641/udp": {}},
            "Labels": {"org.opencontainers.image.title": "Tailscale + BIRD for RouterOS",
                       "org.opencontainers.image.version": ts_ver,
                       "org.opencontainers.image.source":
                           "https://github.com/szczepl/routeros-tailscale-bgp"},
        },
        "rootfs": {"type": "layers", "diff_ids": diff_ids},
        "history": [{"created_by": f"alpine {rootfs_name} + apk {' '.join(PACKAGES)}"},
                    {"created_by": f"tailscale {ts_ver} + tailscale.sh"}],
    }
    if oci_variant:
        config["variant"] = oci_variant
    cfg = json.dumps(config, separators=(",", ":")).encode()
    cfg_name = hashlib.sha256(cfg).hexdigest() + ".json"
    layer_paths = [d.split(":")[1] + "/layer.tar" for d in diff_ids]
    manifest = json.dumps([{"Config": cfg_name, "RepoTags": [a.tag],
                            "Layers": layer_paths}]).encode()

    with tarfile.open(a.output, "w", format=tarfile.GNU_FORMAT) as out:
        def put(name, data):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), 0o644, int(time.time())
            out.addfile(ti, io.BytesIO(data))
        for path, data in zip(layer_paths, layers):
            put(path, data)
        put(cfg_name, cfg)
        put("manifest.json", manifest)
    print(f"wrote {a.output} ({os.path.getsize(a.output) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()

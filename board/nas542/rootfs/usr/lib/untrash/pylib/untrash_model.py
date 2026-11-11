"""Model of this Zyxel NAS5xx (NAS520 / NAS540 / NAS542).

The three share one platform: same SoC, same stock kernel (3.2.54, no board
variants), same PFE firmware, same flash layout.  The NAS520 has no ASM1061
on the backplane, so it has two bays (SoC AHCI) instead of four; the stock
firmware knows that only from its model (intern_disk_chker -n, used for
BAY_NUM and the md0/md1 mirrors).  docs/hardware/README.md, section 10.

Sources, first hit wins:
  1. /run/untrash/device.env (untrash-init, from the PartnerKey install
     record): MODEL_ID = Barebox modelid_<stock slot> (the stock firmware
     writes the model id of its firmware header there on every update),
     FWVERSION = fwversion_<stock slot>, e.g. V5.21(ABAG.15), stored as
     V5.21.ABAG.15 (device.env is sourced by the PartnerKey).
  2. modelname next to the PFE firmware cache (untrash-pfe-extract takes
     etc/modelname from the initramfs of the stock kernel).
  3. unknown: the family, four bays (what the bay code did before).

model() caches the result in /run/untrash/model.json (untrash-model writes
it at boot); UntrashOS reads that file (docs/board-interface.md).
root: test prefix (ZT_MODEL_ROOT), "" on the NAS.
"""
import json
import os
import re

# stock firmware header: model id (tag 0x101), firmware code, bays
MODELS = {
    "B203": {"name": "NAS520", "code": "AASZ", "bays": 2},
    "B103": {"name": "NAS540", "code": "AATB", "bays": 4},
    "B403": {"name": "NAS542", "code": "ABAG", "bays": 4},
}
UNKNOWN = {"id": "", "name": "NAS5xx", "title": "Zyxel NAS5xx", "bays": 4, "source": "unknown"}
ROOT = os.environ.get("ZT_MODEL_ROOT", "")
CACHE = "/run/untrash/model.json"
DEVICE_ENV = "/run/untrash/device.env"
MODELNAME = "/state/firmware/pfe/modelname"


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def _entry(mid, source):
    m = MODELS[mid]
    return {"id": mid, "name": m["name"], "title": "Zyxel " + m["name"], "bays": m["bays"], "source": source}


def detect(root=None):
    root = ROOT if root is None else root
    env = dict(line.split("=", 1) for line in _read(root + DEVICE_ENV).splitlines() if "=" in line)
    mid = env.get("MODEL_ID", "").strip().upper()
    if mid in MODELS:
        return _entry(mid, "stock-env")
    code = re.search(r"[.(]([A-Z]{4})\.\d+", env.get("FWVERSION", ""))
    for k, m in MODELS.items():
        if code and code.group(1) == m["code"]:
            return _entry(k, "stock-env")
    name = _read(root + MODELNAME).strip().upper()
    for k, m in MODELS.items():
        if name == m["name"]:
            return _entry(k, "stock-kernel")
    return dict(UNKNOWN)


def _valid(m):
    return isinstance(m, dict) and isinstance(m.get("name"), str) and m.get("bays") in (2, 4)


def model(root=None):
    """The model dict (id, name, title, bays, source); cached at boot."""
    root = ROOT if root is None else root
    try:
        m = json.loads(_read(root + CACHE) or "null")
        if _valid(m):
            return m
    except ValueError:
        pass
    return detect(root)


def write(root=None):
    """Detect and store /run/untrash/model.json (untrash-model)."""
    root = ROOT if root is None else root
    m = detect(root)
    path = root + CACHE
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump(m, f, sort_keys=True)
        f.write("\n")
    os.replace(path + ".tmp", path)
    return m

#!/usr/bin/env python3
"""PC test of the model detection (pylib/untrash_model.py, untrash-model)
and of the OS reader (untrashos pylib/untrash_device.py): install record,
firmware code, stock kernel modelname, cache, unknown, board.json fallback."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "rootfs", "usr", "lib", "untrash")
OSLIB = os.path.join(HERE, "..", "..", "..", "untrashos", "image", "rootfs", "usr", "lib", "untrash", "pylib")
sys.path.insert(0, os.path.join(LIB, "pylib"))
sys.path.insert(0, OSLIB)
import untrash_device  # noqa: E402
import untrash_model  # noqa: E402

fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


def put(W, path, text):
    os.makedirs(os.path.dirname(W + path), exist_ok=True)
    open(W + path, "w").write(text)


def det(files):
    with tempfile.TemporaryDirectory() as W:
        for p, t in files.items():
            put(W, p, t)
        return untrash_model.detect(W)


ENV = "/run/untrash/device.env"
MN = "/state/firmware/pfe/modelname"
m = det({ENV: "MODEL_ID=B203\nFWVERSION=V5.21.AASZ.5\nACTIVE_SLOT=1\n"})
check("B203 = NAS520 with two bays", (m["name"], m["title"], m["bays"], m["source"]) == ("NAS520", "Zyxel NAS520", 2, "stock-env"))
check("B103 = NAS540, four bays", (det({ENV: "MODEL_ID=B103\n"})["name"], det({ENV: "MODEL_ID=B103\n"})["bays"]) == ("NAS540", 4))
check("B403 = NAS542", det({ENV: "MODEL_ID=B403\n"})["name"] == "NAS542")
check("no model id: firmware code ABAG -> NAS542", det({ENV: "FWVERSION=V5.21.ABAG.15\n"})["name"] == "NAS542")
check("firmware code in the Barebox spelling V5.21(AASZ.5)", det({ENV: "FWVERSION=V5.21(AASZ.5)C0\n"})["name"] == "NAS520")
check("model id wins over the stock kernel", det({ENV: "MODEL_ID=B403\n", MN: "NAS520\n"})["name"] == "NAS542")
m = det({MN: "NAS520\n"})
check("only the stock kernel modelname: NAS520, source stock-kernel", (m["name"], m["bays"], m["source"]) == ("NAS520", 2, "stock-kernel"))
m = det({ENV: "MODEL_ID=X999\n", MN: "NAS999\n"})
check("unknown ids: neutral family, four bays", (m["name"], m["title"], m["bays"], m["source"]) == ("NAS5xx", "Zyxel NAS5xx", 4, "unknown"))
check("nothing at all: unknown", det({})["source"] == "unknown")

with tempfile.TemporaryDirectory() as W:
    put(W, ENV, "MODEL_ID=B203\n")
    r = subprocess.run([sys.executable, os.path.join(LIB, "untrash-model")], env=dict(os.environ, ZT_MODEL_ROOT=W),
                       stdout=subprocess.PIPE, universal_newlines=True)
    c = json.load(open(W + "/run/untrash/model.json"))
    check("untrash-model writes model.json", r.returncode == 0 and c["name"] == "NAS520" and json.loads(r.stdout) == c)
    os.remove(W + ENV)
    check("model() uses the boot cache", untrash_model.model(W)["name"] == "NAS520")
    d = untrash_device.model(W)
    check("OS reader: name, title, bays from model.json", (d["name"], d["title"], d["bays"]) == ("NAS520", "Zyxel NAS520", 2))
    put(W, "/run/untrash/model.json", "{broken")
    check("broken cache: detected again", untrash_model.model(W)["source"] == "unknown")

with tempfile.TemporaryDirectory() as W:
    put(W, "/usr/share/untrash/board.json", json.dumps({"title": "Zyxel NAS540/NAS542"}))
    check("OS reader without model.json: board family from board.json", untrash_device.model(W)["title"] == "Zyxel NAS540/NAS542")
with tempfile.TemporaryDirectory() as W:
    check("OS reader without anything: neutral NAS", untrash_device.model(W)["name"] == "NAS")

print("FAILURES %d" % fails)
sys.exit(1 if fails else 0)

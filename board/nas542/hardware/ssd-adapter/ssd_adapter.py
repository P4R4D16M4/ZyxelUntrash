"""2.5" SSD -> 3.5" bay adapter for the RAM boost (NAS542, any bay).

Builds an STL with Blender (no GUI):

  blender -b -P ssd_adapter.py -- [--variant L|R] [--out FILE]

The SSD's SATA connector must land exactly where a 3.5" drive's connector
would be, or it misses the backplane.  All positions come from the SFF
specifications (numbers in mm), not from measuring a tray:

  SFF-8301 Rev 1.9  3.5" form factor
    width 101.60 (A3), length 147.00 max (A2)
    side holes 28.50 from the connector end (A8), 101.60 apart (A9),
    6.35 above the bottom (A10); 6-32 UNC
    bottom holes 3.18 from the sides (A5), 95.25 apart (A4), 41.28 from
    the connector end (A7), then +44.45 (A6) and +76.20 (A13)
  SFF-8323 Rev 1.6  3.5" serial connector, option B (side screw)
    connector datum C 23.60 from the side hole (A18), datum B 20.68 off
    the drive centreline (A11), connector datum 3.50 above the bottom
  SFF-8201 Rev 3.4  2.5" form factor
    width 69.85 (A4), length 100.45 max (A6), side holes 14.00 / 90.60 from
    the connector end (A52/A53), 3.00 above the bottom (A23); M3
  SFF-8223 Rev 2.7  2.5" serial connector, option 2 (side screw)
    datum C 9.40 from the side hole (A8), datum B 4.80 off the centreline
    (A11), connector datum 3.50 above the bottom

Result: the SSD lies on the tray floor (both connectors 3.50 above the
bottom), flush with one side of the 3.5" outline
(50.80 - 20.68 + 4.80 - 69.85/2 = 0.00) and 0.30 behind the 3.5" connector
end (28.50 - 23.60 - (14.00 - 9.40)).  The adapter is an L: a rail along the
free side (screwed to the SSD's two side holes) and a block in front of the
SSD; it carries the 3.5" side and bottom holes the tray uses.

Variant L: looking at the connector end, bottom down, the SSD lies on the
left.  R is the mirror image.  Which one is right shows a 3.5" disk: its
SATA connector is offset from the middle towards the side where the SSD goes.

Coordinates: x across (0 = SSD side of variant L), y from the connector end
(0) to the front, z up from the bottom.
"""
import sys

import bpy
import bmesh

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
VARIANT = args[args.index("--variant") + 1] if "--variant" in args else "L"
OUT = args[args.index("--out") + 1] if "--out" in args else "ssd-adapter-%s.stl" % VARIANT

# --- specification values -------------------------------------------------
W35, L35 = 101.60, 147.00
SIDE35_Y = (28.50, 28.50 + 101.60)          # side holes from the connector end
SIDE35_Z = 6.35
BOT35_X = 3.18
BOT35_Y = (41.28, 41.28 + 44.45, 41.28 + 76.20)
W25, L25 = 69.85, 100.45
SSD_Y0 = 28.50 - 23.60 - (14.00 - 9.40)      # 0.30: SSD connector end behind the 3.5" end
SSD_X0 = W35 / 2 - 20.68 + 4.80 - W25 / 2    # 0.00: flush with the side
SIDE25_Y = (SSD_Y0 + 14.00, SSD_Y0 + 90.60)
SIDE25_Z = 3.00

# --- print choices ----------------------------------------------------------
H = 15.0            # rail and block height (3.5" allows up to 26.10)
CLR = 0.40          # clearance around the SSD
WALL = 3.0          # wall between an M3 head and the SSD (M3x5 for 7 mm SSDs)
M3_HOLE = 3.4
M3_HEAD = 6.2
TRAY_HOLE = 2.9     # 6-32 self-tapping / 3 mm tray pins
TRAY_DEPTH = 7.0
POCKET_WALL = 2.4   # lightening pockets: walls and floor
FLOOR = 3.0

RAIL_X0 = SSD_X0 + W25 + CLR                 # inner face of the rail
FRONT_Y0 = SSD_Y0 + L25 + CLR                # rear face of the front block


def box(x0, y0, z0, x1, y1, z1, name="box"):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x = x0 if v.co.x < 0 else x1
        v.co.y = y0 if v.co.y < 0 else y1
        v.co.z = z0 if v.co.z < 0 else z1
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def cyl(axis, cx, cy, cz, d, length, name="cyl"):
    """Cylinder along axis 'x', 'y' or 'z', starting at (cx, cy, cz)."""
    bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=d / 2, depth=length)
    ob = bpy.context.object
    ob.name = name
    if axis == "x":
        ob.rotation_euler = (0, 1.5707963, 0)
        ob.location = (cx + length / 2, cy, cz)
    elif axis == "y":
        ob.rotation_euler = (1.5707963, 0, 0)
        ob.location = (cx, cy + length / 2, cz)
    else:
        ob.location = (cx, cy, cz + length / 2)
    return ob


def apply(target, tool, op):
    m = target.modifiers.new("b", "BOOLEAN")
    m.operation = op
    m.solver = "EXACT"
    m.object = tool
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.data.objects.remove(tool, do_unlink=True)


bpy.ops.wm.read_factory_settings(use_empty=True)

# L shape: rail along the free side + block in front of the SSD
part = box(RAIL_X0, 0, 0, W35, L35, H, "adapter")
apply(part, box(0, FRONT_Y0, 0, W35, L35, H), "UNION")

# lightening pockets from the top (keep walls around every hole)
apply(part, box(RAIL_X0 + POCKET_WALL, 40.0, FLOOR, W35 - POCKET_WALL, 78.0, H + 1), "DIFFERENCE")
apply(part, box(POCKET_WALL + 8, FRONT_Y0 + POCKET_WALL, FLOOR, W35 - POCKET_WALL - 8, L35 - 26.0, H + 1), "DIFFERENCE")

# SSD side screws: M3 through the rail wall, head counterbore from the outside
for y in SIDE25_Y:
    apply(part, cyl("x", RAIL_X0 - 1, y, SIDE25_Z, M3_HOLE, WALL + 2), "DIFFERENCE")
    apply(part, cyl("x", RAIL_X0 + WALL, y, SIDE25_Z, M3_HEAD, W35 - RAIL_X0 - WALL + 1), "DIFFERENCE")

# 3.5" side holes: the rail side has both; on the SSD side only the front one
# lies in the block (the rear one is covered by the SSD)
for y in SIDE35_Y:
    apply(part, cyl("x", W35 - TRAY_DEPTH, y, SIDE35_Z, TRAY_HOLE, TRAY_DEPTH + 1), "DIFFERENCE")
apply(part, cyl("x", -1, SIDE35_Y[1], SIDE35_Z, TRAY_HOLE, TRAY_DEPTH + 1), "DIFFERENCE")

# 3.5" bottom holes (rail side: all three, SSD side: the front one)
for y in BOT35_Y:
    apply(part, cyl("z", W35 - BOT35_X, y, -1, TRAY_HOLE, TRAY_DEPTH + 1), "DIFFERENCE")
apply(part, cyl("z", BOT35_X, BOT35_Y[2], -1, TRAY_HOLE, TRAY_DEPTH + 1), "DIFFERENCE")

if VARIANT == "R":
    part.scale.x = -1
    bpy.context.view_layer.objects.active = part
    part.select_set(True)
    bpy.ops.object.transform_apply(scale=True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    part.location.x = W35

for o in bpy.context.scene.objects:
    o.select_set(o == part)
bpy.ops.export_mesh.stl(filepath=OUT, use_selection=True, ascii=False)
print("ADAPTER %s -> %s  SSD x0=%.2f y0=%.2f  rail x>=%.2f  front y>=%.2f  SSD screws y=%s z=%.2f" % (
    VARIANT, OUT, SSD_X0, SSD_Y0, RAIL_X0, FRONT_Y0, ["%.2f" % y for y in SIDE25_Y], SIDE25_Z))

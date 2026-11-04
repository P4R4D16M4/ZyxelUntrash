# 2.5" SSD adapter for a 3.5" bay (RAM boost)

A printed adapter that holds a 2.5" SATA SSD in a NAS542 drive tray so that
its SATA connector meets the backplane exactly where a 3.5" disk's connector
would.  For the RAM boost (Storage → RAM boost); any of the 4 bays.

| File | |
|---|---|
| `ssd_adapter.py` | the model (Blender, parametric): `blender -b -P ssd_adapter.py -- --variant L --out ssd-adapter-L.stl` |
| `ssd-adapter-L.stl`, `ssd-adapter-R.stl` | the two mirror variants, 101.6 × 147 × 15 mm |

All positions come from the SFF specifications (SFF-8301, -8323 for 3.5",
SFF-8201, -8223 for 2.5"; values and derivation in `ssd_adapter.py`), not from
measuring a NAS542 tray.  Every 3.5" disk follows them, so the tray and
backplane do too, but the first print is a fit test.

## How it sits

- The SSD lies **on the tray floor**: both standards put the connector 3.50 mm
  above the drive's bottom.
- It lies **flush with one side** of the 3.5" outline and 0.30 mm behind the
  3.5" connector end.
- The adapter is an L-shape: a rail along the free side and a block in front
  of the SSD.  It carries the 3.5" side holes (6.35 mm above the bottom) and
  bottom holes for the tray.
- The SSD is fastened with **2 × M3 screws** through the rail into its side
  holes (heads sink into the rail).  Use M3×5 for 7 mm SSDs and M3×5 or M3×6
  for 9.5 mm SSDs; the spec allows 2 / 3 mm penetration.

## Which variant

Hold a 3.5" disk with the SATA connector facing you, circuit board down.

- The connector is offset to the **left** of the middle → print **L**.
- Offset to the right → print **R**.

The SSD goes to the side the connector is offset to.

## Limitation

On the SSD side only the **front** 3.5" side hole and the front bottom hole
exist.  The rear ones would lie in the SSD itself.  If the tray has a pin or a
screw there, leave it out, so it does not press on the SSD.

## Print

- PETG (or PLA), 0.2 mm layers, 3 perimeters, 20–30 % infill.
- No supports: lie it flat as modelled, open pockets facing up.
- About 35–45 g at 25 % infill.
- The 2.9 mm tray holes take 6-32 drive screws (self-tapping) or 3 mm tray pins.
  Reprint with `TRAY_HOLE` changed if they are too tight.

## Fit test before trusting it

1. Screw the SSD in and put the adapter into the tray **outside the NAS**.
2. Compare it with a 3.5" disk in a second tray: the SSD's connector must sit
   at the same place, in all three directions.
3. Only then slide it into a bay, gently, with the NAS off.
   If the connector does not meet the backplane, do not force it.

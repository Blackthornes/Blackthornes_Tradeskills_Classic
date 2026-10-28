"""Writes Data/Travel.lua: the flight masters, flights, docks and rides the
arrow plans a trip with (Logic/Travel.lua).

Run from the repository root with the Forever client's game tables exported
as CSV, one file per table, in one folder:

    python tools/make_travel.py <tables> <build>

It reads TaxiNodes (each flight master: its name, continent, spot and side),
TaxiPath (the flights between them), TaxiPathNode (the points each flight
goes through, for how long it is; looked for beside the tables or in their
extra/ folder) and GameObjects (the signs on the docks and zeppelin towers,
for where a boat or zeppelin leaves from). What it writes:

- flights[id] = { name, side, continent, north, west, zone }: every flight
  master of the Alliance ("A"), the Horde ("H") or both ("AH"). Rows the
  client keeps for transports, quest flights, tests and cut content are
  left out, and so are nodes neither side can use or
  no flight reaches.
- paths = { from, to, ... }: one flight a pair, between kept flight masters.
- lengths = { yards, ... }: how far each flight in paths really goes, along
  its points, one a pair in the same order; 0 when the tables have no points
  for it (the arrow then guesses from the straight line).
- docks[key] = { name, continent, north, west, zone }: where each boat and
  zeppelin leaves from, read from the sign or flight master that stands
  there (DOCKS below names which), or the boarding spot seen in game on a
  zone's map, which beats the tables' row. Never a made up spot.
- rides = { { a, b, kind, side }, ... }: the boats and zeppelins between
  docks, both ways.

The client's world coordinates are kept as they are: north and west, in
yards, on continent 0 (Eastern Kingdoms) or 1 (Kalimdor), as
C_Map.GetWorldPosFromMapPos gives them.

Never edit the output by hand; rerun this when the client's tables change.
"""

import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_package import PRIVATE  # noqa: E402

OUT = Path("Data/Travel.lua")

CONTINENTS = (0, 1)
ALLIANCE, HORDE = 1, 2
LEFT_OUT = ("Transport,", "Generic,", "Quest Path", "zzOLD", "Programmer Isle")

# Where each ride leaves from: the table row that stands there. "go" is a
# GameObjects ID (a dock's sign), "taxi" a TaxiNodes ID (the flight master
# or transport point at that dock, where the table has no sign). "seen" is
# the boarding spot read off the game's map in play, (UiMap ID, x, y) in
# percent; a spot seen in game beats the tables' row, which can be a road
# sign some way off.
DOCKS = [
    ("auberdine", "Auberdine", "Darkshore", ("go", 176364)),
    ("menethil", "Menethil Harbor", "Wetlands", ("go", 176369)),
    ("theramore", "Theramore", "Dustwallow Marsh", ("go", 21065)),
    ("ratchet", "Ratchet", "The Barrens", ("sign", "Maiden's Fancy")),
    ("bootybay", "Booty Bay", "Stranglethorn Vale", ("taxi", 18)),
    ("ruttheran", "Rut'theran Village", "Teldrassil", ("taxi", 27)),
    # The Orgrimmar tower has a platform for each zeppelin (2026-10-23).
    ("orgrimmar", "Orgrimmar", "Durotar", ("seen", (1411, 50.8, 13.7))),
    ("orgrimmargromgol", "Orgrimmar", "Durotar", ("seen", (1411, 50.6, 12.8))),
    # The Undercity tower's Orgrimmar platform; its Grom'gol one is on the
    # same tower and waits for a spot seen in game.
    ("undercity", "Undercity", "Tirisfal Glades", ("seen", (1420, 60.7, 58.8))),
    ("gromgol", "Grom'gol", "Stranglethorn Vale", ("taxi", 47)),
]

RIDES = [
    ("menethil", "theramore", "boat", "A"),
    ("menethil", "auberdine", "boat", "A"),
    ("auberdine", "ruttheran", "boat", "A"),
    ("bootybay", "ratchet", "boat", "AH"),
    ("orgrimmar", "undercity", "zeppelin", "H"),
    ("orgrimmargromgol", "gromgol", "zeppelin", "H"),
    ("undercity", "gromgol", "zeppelin", "H"),
]


def rows(folder, name):
    with open(Path(folder) / f"{name}.csv", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def private(text):
    return any(pattern.search(text) for _, pattern in PRIVATE)


def side_of(row):
    flags = int(row["Flags"] or 0)
    side = ""
    if flags & ALLIANCE or int(row["MountCreatureID_1"] or 0):
        side += "A"
    if flags & HORDE or int(row["MountCreatureID_0"] or 0):
        side += "H"
    return side


def zone_of(name):
    return name.split(", ", 1)[1] if ", " in name else name


def read_flights(folder):
    flights = {}
    for row in rows(folder, "TaxiNodes"):
        name = row["Name_lang"].strip()
        continent = int(row["ContinentID"] or -1)
        if not name or name.startswith(LEFT_OUT) or continent not in CONTINENTS:
            continue
        if private(name):
            continue
        side = side_of(row)
        north, west = float(row["Pos_0"]), float(row["Pos_1"])
        if not side or (north == 0 and west == 0):
            continue
        flights[int(row["ID"])] = (name, side, continent, round(north, 1), round(west, 1), zone_of(name))
    return flights


def read_paths(folder, flights):
    """Each flight between kept flight masters: { (from, to): path ID }."""
    paths = {}
    for row in rows(folder, "TaxiPath"):
        a, b = int(row["FromTaxiNode"]), int(row["ToTaxiNode"])
        if a in flights and b in flights and a != b:
            paths.setdefault((a, b), int(row["ID"]))
    return paths


def path_nodes(folder):
    for place in (Path(folder), Path(folder) / "extra"):
        if (place / "TaxiPathNode.csv").exists():
            return rows(place, "TaxiPathNode")
    raise SystemExit("make_travel: no TaxiPathNode.csv beside the tables or in extra/")


def read_lengths(folder, wanted):
    """How far each path goes, in yards, along its points: { path ID: yards }.
    A step to another continent is a jump, not flown, so it adds nothing."""
    points = {}
    for row in path_nodes(folder):
        path = int(row["PathID"])
        if path in wanted:
            points.setdefault(path, []).append((
                int(row["NodeIndex"]), int(row["ContinentID"]),
                float(row["Loc_0"]), float(row["Loc_1"]), float(row["Loc_2"]),
            ))
    lengths = {}
    for path, nodes in points.items():
        nodes.sort()
        yards = 0.0
        for before, after in zip(nodes, nodes[1:]):
            if before[1] == after[1]:
                yards += sum((after[i] - before[i]) ** 2 for i in (2, 3, 4)) ** 0.5
        lengths[path] = round(yards)
    return lengths


def seen_spot(maps, ui_map, x, y):
    """A spot on a zone's map (percent, as the game shows it) in world
    north and west, by the map's corners in UiMapAssignment."""
    row = maps.get(ui_map)
    if not row:
        return None
    north_lo, west_lo = float(row["Region_0"]), float(row["Region_1"])
    north_hi, west_hi = float(row["Region_3"]), float(row["Region_4"])
    north = north_hi - (y / 100) * (north_hi - north_lo)
    west = west_hi - (x / 100) * (west_hi - west_lo)
    return int(row["MapID"]), round(north, 1), round(west, 1)


def read_docks(folder):
    signs = {int(row["ID"]): row for row in rows(folder, "GameObjects")}
    by_name = {}
    for row in signs.values():
        by_name.setdefault(row["Name_lang"].split(" - ")[0].strip(), row)
    nodes = {int(row["ID"]): row for row in rows(folder, "TaxiNodes")}
    maps = {
        int(row["UiMapID"]): row
        for row in rows(folder, "UiMapAssignment")
        if int(row["OrderIndex"] or 0) == 0
    }

    docks = {}
    for key, name, zone, (kind, ref) in DOCKS:
        if kind == "seen":
            spot = seen_spot(maps, *ref)
            if not spot:
                raise SystemExit(f"make_travel: no map for the {name} dock ({kind} {ref})")
            docks[key] = (name,) + spot + (zone,)
            continue
        if kind == "go":
            row = signs.get(ref)
            continent = row and int(row["OwnerID"])
        elif kind == "sign":
            row = by_name.get(ref)
            continent = row and int(row["OwnerID"])
        else:
            row = nodes.get(ref)
            continent = row and int(row["ContinentID"])
        if not row:
            raise SystemExit(f"make_travel: no row for the {name} dock ({kind} {ref})")
        docks[key] = (name, continent, round(float(row["Pos_0"]), 1), round(float(row["Pos_1"]), 1), zone)
    return docks


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write(build, flights, paths, lengths, docks):
    out = [
        "-- Blackthornes Farmer -- Data/Travel.lua",
        "-- Generated by tools/make_travel.py from the Forever client's game tables",
        f"-- (build {build}); never edit by hand. Flight masters, flights, docks",
        "-- and rides only, for the arrow's trips (Logic/Travel.lua).",
        "",
        "local _, ns = ...",
        "",
        "ns.TRAVEL_DATA = {",
        f"    build = {lua_string(build)},",
        "",
        "    -- [node] = { name, side, continent, north, west, zone }",
        "    flights = {",
    ]
    for node in sorted(flights):
        name, side, continent, north, west, zone = flights[node]
        out.append(f"        [{node}] = {{ {lua_string(name)}, \"{side}\", {continent}, {north}, {west}, {lua_string(zone)} }},")
    out += ["    },", "", "    -- from, to: one flight a pair.", "    paths = {"]
    for index in range(0, len(paths), 8):
        chunk = paths[index:index + 8]
        out.append("        " + " ".join(f"{a}, {b}," for a, b in chunk))
    out += ["    },", "", "    -- How far each flight above goes, yards, in the same order (0: not known).", "    lengths = {"]
    for index in range(0, len(paths), 12):
        chunk = paths[index:index + 12]
        out.append("        " + " ".join(f"{lengths.get(pair, 0)}," for pair in chunk))
    out += ["    },", "", "    -- [key] = { name, continent, north, west, zone }", "    docks = {"]
    for key in sorted(docks):
        name, continent, north, west, zone = docks[key]
        out.append(f"        {key} = {{ {lua_string(name)}, {continent}, {north}, {west}, {lua_string(zone)} }},")
    out += ["    },", "", "    -- { a, b, kind, side }: both ways.", "    rides = {"]
    for a, b, kind, side in RIDES:
        out.append(f"        {{ \"{a}\", \"{b}\", \"{kind}\", \"{side}\" }},")
    out += ["    },", "}", ""]
    OUT.write_text("\n".join(out), encoding="utf-8", newline="\n")


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: python tools/make_travel.py <tables> <build>")
    folder, build = argv[1], argv[2]
    flights = read_flights(folder)
    ids = read_paths(folder, flights)
    paths = sorted(ids)
    # A flight master no flight reaches is no use on a trip.
    used = {node for pair in paths for node in pair}
    flights = {node: row for node, row in flights.items() if node in used}
    by_path = read_lengths(folder, set(ids.values()))
    lengths = {pair: by_path[ids[pair]] for pair in paths if ids[pair] in by_path}
    docks = read_docks(folder)
    write(build, flights, paths, lengths, docks)
    print(f"make_travel: {len(flights)} flight masters, {len(paths)} flights "
          f"({len(lengths)} with their real length), {len(docks)} docks -> {OUT}")


if __name__ == "__main__":
    main(sys.argv)

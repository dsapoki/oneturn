"""Builds data/ch-chademo.json: every public CHAdeMO charging station in Switzerland, from the Swiss Federal Office
of Energy's open data (BFE / SFOE, ich-tanke-strom.ch; licence: open use, source must be named). Stations of the
JOYA network (formerly GOFAST, Energie 360°, MOVE and Swisscharge) are marked. The federal data has no prices.
Run daily by .github/workflows/ch-chargers.yml; the OneTurn web app reads the file for routes in Switzerland."""
import datetime
import gzip
import json
import math
import re
import urllib.request

URL = "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/data/oicp/ch.bfe.ladestellen-elektromobilitaet.json"
JOYA = {"CH*360": "Energie 360°", "CH*CCC": "MOVE", "CH*SUI": "Swisscharge"}   # operator IDs of the brands now under JOYA


def name_of(e):
    names = {n.get("lang"): n.get("value") for n in e.get("ChargingStationNames") or []}
    return (names.get("en") or names.get("fr") or names.get("de") or next(iter(names.values()), "") or "").strip()


def dc_kw(e):
    p = [float(f.get("power") or 0) for f in e.get("ChargingFacilities") or [] if f.get("powertype") == "DC"]
    kw = max(p) if p else 0
    if len(e.get("Plugs") or []) > 1:   # shared with CCS: the CHAdeMO side is 50 kW on such units
        kw = min(kw, 50) if kw else 50
    return round(kw)


def main():
    raw = urllib.request.urlopen(URL, timeout=180).read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    data = json.loads(raw)
    found = []
    for block in data["EVSEData"]:
        op_id, op_name = block.get("OperatorID") or "", block.get("OperatorName") or ""
        for e in block.get("EVSEDataRecord") or []:
            if "CHAdeMO" not in (e.get("Plugs") or []) or "public" not in (e.get("Accessibility") or "").lower():
                continue
            try:
                lat, lon = [float(v) for v in e["GeoCoordinates"]["Google"].split()]
            except (KeyError, ValueError, AttributeError):
                continue
            nm = name_of(e)
            joya = op_id in JOYA or "joya" in op_name.lower()
            brand = "GOFAST" if re.search(r"gofast", nm, re.I) else JOYA.get(op_id, op_name)
            ad = e.get("Address") or {}
            found.append(dict(i=e.get("ChargingStationId") or e.get("EvseID"), n=nm, lat=round(lat, 6), lon=round(lon, 6),
                              a=", ".join(x for x in [ad.get("Street"), ad.get("City")] if x),
                              o=("JOYA (" + brand + ")") if joya else op_name, j=1 if joya else 0, k=dc_kw(e), q=1))
    # one entry per site: same network within about 40 m
    found.sort(key=lambda s: (s["o"], s["lat"], s["lon"]))
    sites = []
    for s in found:
        for t in sites:
            if (t["o"] == s["o"] and abs(t["lat"] - s["lat"]) * 111320 < 40
                    and abs(t["lon"] - s["lon"]) * 111320 * math.cos(math.radians(s["lat"])) < 40):
                t["q"] += 1
                t["k"] = max(t["k"], s["k"])
                break
        else:
            sites.append(dict(s))
    sites.sort(key=lambda s: s["i"])
    out = dict(source="Swiss Federal Office of Energy (BFE), ich-tanke-strom.ch",
               day=datetime.date.today().isoformat(), stations=sites)
    with open("data/ch-chademo.json", "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print(len(found), "CHAdeMO points,", len(sites), "sites,", sum(s["j"] for s in sites), "JOYA sites")


if __name__ == "__main__":
    main()

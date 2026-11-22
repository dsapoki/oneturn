"""One-off: Swiss CHAdeMO stations in Open Charge Map vs the federal list (data/ch-chademo.json)."""
import json, math, urllib.request, collections
URL = "https://api.openchargemap.io/v3/poi/?output=json&countrycode=CH&connectiontypeid=2&maxresults=5000&compact=true&verbose=false"
req = urllib.request.Request(URL, headers={"User-Agent": "OneTurn-compare/1.0"})
try:
    pois = json.loads(urllib.request.urlopen(req, timeout=120).read())
except Exception as e:
    print("OCM fetch failed:", e); raise SystemExit(0)
fed = json.load(open("data/ch-chademo.json"))["stations"]
print("OCM CHAdeMO POIs in CH:", len(pois), "| federal sites:", len(fed))
def d(a, b, c, e):
    return math.hypot((a - c) * 111320, (b - e) * 111320 * math.cos(math.radians(a)))
st = collections.Counter(); only_ocm = []
for p in pois:
    ai = p.get("AddressInfo") or {}; la, lo = ai.get("Latitude"), ai.get("Longitude")
    status = (p.get("StatusTypeID"), p.get("UsageTypeID"))
    near = min((d(la, lo, f["lat"], f["lon"]) for f in fed), default=1e9)
    key = "within 150 m of a federal site" if near < 150 else "within 500 m" if near < 500 else "not in federal list"
    st[key] += 1
    if near >= 500: only_ocm.append((p.get("ID"), ai.get("Title"), ai.get("Town"), p.get("OperatorID"), p.get("StatusTypeID"), p.get("UsageTypeID"), p.get("DateLastVerified") or p.get("DateLastStatusUpdate")))
print(dict(st))
ops = collections.Counter(x[3] for x in only_ocm); print("only-OCM by operator id:", ops.most_common(15))
stat = collections.Counter(x[4] for x in only_ocm); print("only-OCM by status id (50 operational, 150 planned, 100/200 not operational, 0/None unknown):", stat.most_common())
use = collections.Counter(x[5] for x in only_ocm); print("only-OCM by usage id (1 public, 4 public membership, 5 public pay at location, 7 public notice required, 2 private restricted, 3 private owner, 6 private visitors):", use.most_common())
for x in only_ocm[:40]: print("  ", x)
fed_only = sum(1 for f in fed if min((d(f["lat"], f["lon"], (p.get("AddressInfo") or {}).get("Latitude"), (p.get("AddressInfo") or {}).get("Longitude")) for p in pois), default=1e9) >= 500)
print("federal sites with no OCM CHAdeMO entry within 500 m:", fed_only, "of", len(fed))

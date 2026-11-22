"""One-off look at the Swiss federal charging-station data (BFE/SFOE): structure, operators, CHAdeMO, any price fields."""
import json, urllib.request, collections, sys
URL = "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/data/oicp/ch.bfe.ladestellen-elektromobilitaet.json"
raw = urllib.request.urlopen(URL, timeout=120).read()
print("bytes", len(raw))
d = json.loads(raw)
print("top keys", list(d)[:10])
recs = d["EVSEData"]
print("operators blocks", len(recs))
evses = [(blk.get("OperatorName"), blk.get("OperatorID"), e) for blk in recs for e in blk.get("EVSEDataRecord", [])]
print("evses", len(evses))
print("first record keys", sorted(evses[0][2].keys()))
print(json.dumps(evses[0][2], ensure_ascii=False)[:1500])
plugs = collections.Counter(p for _, _, e in evses for p in (e.get("Plugs") or []))
print("plugs", plugs.most_common())
ch = [(n, i, e) for n, i, e in evses if any("CHAdeMO" in p for p in (e.get("Plugs") or []))]
print("chademo evses", len(ch))
ops = collections.Counter((n, i) for n, i, _ in ch)
for (n, i), c in ops.most_common(60): print("  ", c, i, n)
keys = collections.Counter(k for _, _, e in evses for k in e.keys())
print("all keys", keys.most_common())
pricey = [k for k in keys if any(w in k.lower() for w in ("pric", "tarif", "cost", "fee"))]
print("price-like keys", pricey)
for k in pricey[:5]:
    ex = next(e[k] for _, _, e in evses if e.get(k))
    print(k, json.dumps(ex, ensure_ascii=False)[:500])
joya = [(n, i, e) for n, i, e in ch if any(w in (n or "").lower() for w in ("joya", "gofast", "swisscharge", "move", "energie 360", "energie360"))]
print("joya-ish chademo", len(joya))
for n, i, e in joya[:3]: print(json.dumps(e, ensure_ascii=False)[:1200])

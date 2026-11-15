#!/usr/bin/env python3
"""Writes themes/christmas/config.json: the 2026 Christmas season for TV Home (patch 0005).

One row per day from 14 November 2026 to 1 January 2027:
  greeting  - replaces "Good afternoon" (festival_days; 40 characters at most)
  moment    - what plays the first time Home opens that day ("+" joins several); in December the day's
              ornament drops onto the tree first by itself
  gnome     - where the gnome hides (from 1 December): tile:N, pill:inputs|wifi|settings, date, tree,
              dock:left|right
  sky       - moon, solstice, meteors
  style     - multicolour (lights), sweater (knitted pills), santa (Christmas Eve tracker), holiday (gnome asleep)
  line      - a sentence for the Christmas screensaver, under the greeting (special days only)

Usage: themes/christmas/make-config.py [--preview YYYY-MM-DD [--moment NAME@F]] [-o FILE]
--preview writes a copy that shows that day now (and holds a moment still), for screenshots only.
"""
import argparse
import json
import os
from datetime import date, timedelta

CHRISTMAS = date(2026, 12, 25)
NEW_YEAR = date(2027, 1, 1)

# Moments rotate on ordinary days; special days are set below.
ROTATION = ["flurry", "shooting_star", "chase", "snowflake", "sleigh", "cardinal", "aurora"]

GNOME = {
    1: "tile:1", 2: "pill:settings", 3: "date", 4: "tile:3", 5: "dock:left", 6: "tree", 7: "pill:inputs",
    8: "tile:0", 9: "dock:right", 10: "date", 11: "tile:2", 12: "pill:wifi", 13: "tree", 14: "tile:1",
    15: "dock:left", 16: "pill:settings", 17: "date", 18: "tile:3", 19: "dock:right", 20: "tile:0",
    21: "pill:inputs", 22: "tile:2", 23: "date", 24: "tree", 25: "tree", 26: "tile:0", 27: "tile:2",
    28: "tree", 29: "tile:3", 30: "tile:1", 31: "date",
}


def sleeps(d):
    return (CHRISTMAS - d).days


def row(d, i):
    n = sleeps(d)
    r = {"greeting": f"{n} sleeps to Christmas", "moment": ROTATION[i % len(ROTATION)], "gnome": "", "sky": "",
         "style": "", "line": ""}
    if d.month == 12 and d.day <= 31:
        r["gnome"] = GNOME[d.day]
    if d == NEW_YEAR:
        r["gnome"] = "tree"
    special = {
        date(2026, 11, 14): {"moment": "lights_on", "line": "The lights are up."},
        date(2026, 11, 24): {"sky": "moon", "moment": "sleigh", "line": "Full moon tonight."},
        date(2026, 11, 29): {"moment": "tree_arrives", "greeting": "Advent begins · 26 sleeps to go",
                             "line": "Advent Sunday: the tree is up on Home."},
        date(2026, 12, 1): {"moment": "gnome_arrives",
                            "line": "A gnome has moved into Home. He hides somewhere new every day."},
        date(2026, 12, 13): {"sky": "meteors", "moment": "shooting_star",
                             "greeting": "12 sleeps · Geminids tonight",
                             "line": "Tonight the Geminids peak: shooting stars after 9 pm."},
        date(2026, 12, 14): {"sky": "meteors", "moment": "shooting_star",
                             "greeting": "11 sleeps · Geminids again tonight",
                             "line": "More Geminids tonight. Before dawn is best."},
        date(2026, 12, 18): {"style": "sweater+multicolour", "moment": "chase",
                             "greeting": "7 sleeps · Ugly Sweater Day",
                             "line": "Ugly Sweater Day. Wear the worst one you own."},
        date(2026, 12, 21): {"sky": "solstice", "moment": "aurora", "greeting": "4 sleeps · the longest night",
                             "line": "The longest night of the year. Days get longer from tomorrow."},
        date(2026, 12, 23): {"sky": "moon", "moment": "sleigh", "greeting": "Christmas Eve Eve · 2 sleeps",
                             "line": "The moon is full tonight."},
        date(2026, 12, 24): {"sky": "moon", "moment": "star+sleigh", "style": "santa+multicolour",
                             "greeting": "Christmas Eve", "line": "Santa sets off tonight."},
        date(2026, 12, 25): {"moment": "presents+flurry", "style": "multicolour", "greeting": "Merry Christmas",
                             "line": ""},
        date(2026, 12, 26): {"moment": "chase", "style": "holiday", "greeting": "Happy Boxing Day",
                             "line": ""},
        date(2026, 12, 31): {"moment": "chase", "style": "holiday+multicolour",
                             "greeting": "New Year's Eve · last day of 2026",
                             "line": "See you in 2027!"},
        NEW_YEAR: {"moment": "fireworks", "style": "holiday+multicolour", "greeting": "Happy New Year",
                   "line": ""},
    }
    if date(2026, 12, 27) <= d <= date(2026, 12, 30):
        left = (NEW_YEAR - d).days
        r.update({"style": "holiday", "greeting": f"Happy Holidays · {left} days to 2027",
                  "line": ""})
    r.update(special.get(d, {}))
    assert len(r["greeting"]) <= 40, r["greeting"]
    return r


def build(preview=None, moment=None):
    days, calendar = {}, {}
    d, i = date(2026, 11, 14), 0
    while d <= NEW_YEAR:
        r = row(d, i)
        days[d.isoformat()] = r["greeting"]
        calendar[d.isoformat()] = {k: r[k] for k in ("moment", "gnome", "sky", "style", "line") if r[k]}
        d += timedelta(days=1)
        i += 1
    cfg = {
        "festival": "christmas",
        "festival_until": NEW_YEAR.isoformat(),
        "accent_color": "#FFD27F",
        "background_color": "#070D1B",
        "festival_tree_from": "2026-11-29",
        "festival_decor": ["sky", "snow", "lights", "tree", "gnome", "snowcaps", "weather", "moments"],
        "festival_days": days,
        "festival_calendar": calendar,
    }
    if preview:
        cfg["festival_preview_date"] = preview
    if moment:
        cfg["festival_preview_moment"] = moment
    return cfg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview")
    ap.add_argument("--moment")
    ap.add_argument("-o", "--out")
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    out = a.out or os.path.join(here, "config.json")
    with open(out, "w") as f:
        json.dump(build(a.preview, a.moment), f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(out)


if __name__ == "__main__":
    main()

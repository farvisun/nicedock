#!/usr/bin/env python3
"""Independent expansion of an ICS feed, used to cross-check the app's RFC 5545 reader (Sources/CoolDock/Services/ICS.swift).

Recurrence comes from python-dateutil's rrule/rruleset and time zones from zoneinfo (the system tz database), so the
only shared logic with the Swift code is reading content lines. Writes one TSV row per occurrence overlapping the
window, sorted:

    uid  start  end  title

Timed events use UTC ("2026-10-27T16:00:00Z"); all-day events use dates ("2026-10-31", end exclusive) read as UTC.

    /usr/bin/python3 Tests/Scripts/ics_oracle.py <feed.ics> <from YYYY-MM-DD> <to YYYY-MM-DD> > expected.tsv

(Apple's /usr/bin/python3 has dateutil when installed with `pip3 install --user python-dateutil`.)
"""
import re
import sys
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from dateutil.rrule import rrulestr, rruleset

UTC = timezone.utc


def content_lines(raw):
    text = raw.decode("utf-8", errors="replace")
    return [l for l in re.sub(r"\r?\n[ \t]", "", text).splitlines() if l]


def split_property(line):
    i, n = 0, len(line)
    while i < n and line[i] not in ";:":
        i += 1
    name, params = line[:i].upper(), {}
    while i < n and line[i] == ";":
        i += 1
        start = i
        while i < n and line[i] not in "=;:":
            i += 1
        key, value = line[start:i].upper(), []
        if i < n and line[i] == "=":
            i += 1
            quoted = False
            while i < n:
                c = line[i]
                if c == '"':
                    quoted = not quoted
                elif not quoted and c in ";:":
                    break
                else:
                    value.append(c)
                i += 1
        params[key] = "".join(value)
    if i >= n or line[i] != ":":
        return None
    return name, params, line[i + 1:]


def unescape(s):
    return re.sub(r"\\(.)", lambda m: "\n" if m.group(1) in "nN" else m.group(1), s)


def vevents(lines):
    events, current, depth = [], None, 0
    for line in lines:
        p = split_property(line)
        if not p:
            continue
        name, params, value = p
        if name == "BEGIN":
            if value.upper() == "VEVENT" and current is None:
                current, depth = {}, 0
            elif current is not None:
                depth += 1
            continue
        if name == "END":
            if current is not None:
                if depth == 0:
                    events.append(current)
                    current = None
                else:
                    depth -= 1
            continue
        if current is not None and depth == 0:
            current.setdefault(name, []).append((params, value))
    return events


def parse_time(value, params):
    """date for all-day, aware datetime otherwise (floating times are read as UTC, none occur in the fixtures)."""
    v = value.strip()
    if params.get("VALUE", "").upper() == "DATE" or len(v) == 8:
        return date(int(v[:4]), int(v[4:6]), int(v[6:8]))
    dt = datetime(int(v[:4]), int(v[4:6]), int(v[6:8]), int(v[9:11]), int(v[11:13]), min(int(v[13:15] or 0), 59))
    if v.endswith("Z"):
        return dt.replace(tzinfo=UTC)
    tzid = params.get("TZID")
    return dt.replace(tzinfo=ZoneInfo(tzid) if tzid else UTC)


def as_naive(d):
    return datetime(d.year, d.month, d.day) if isinstance(d, date) and not isinstance(d, datetime) else d


def times(entries):
    out = []
    for params, value in entries:
        for item in value.split(","):
            out.append(parse_time(item.split("/")[0], params))
    return out


def duration(value):
    m = re.fullmatch(r"([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", value.strip())
    if not m:
        return None
    sign = -1 if m.group(1) == "-" else 1
    w, d, h, mi, s = (int(g or 0) for g in m.groups()[1:])
    return sign * timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


def fix_until(rule, start):
    """dateutil wants UNTIL in UTC for aware DTSTARTs and naive for all-day ones."""
    m = re.search(r"UNTIL=([0-9TZ]+)", rule)
    if not m:
        return rule
    u = m.group(1)
    if isinstance(start, date) and not isinstance(start, datetime):
        return rule.replace(u, u[:8])
    if u.endswith("Z"):
        return rule
    if len(u) == 8:
        local = datetime(int(u[:4]), int(u[4:6]), int(u[6:8]), 23, 59, 59, tzinfo=start.tzinfo)
    else:
        local = datetime(int(u[:4]), int(u[4:6]), int(u[6:8]), int(u[9:11]), int(u[11:13]), int(u[13:15]), tzinfo=start.tzinfo)
    return rule.replace(u, local.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ"))


def main():
    path, lo_s, hi_s = sys.argv[1:4]
    lo_d, hi_d = date.fromisoformat(lo_s), date.fromisoformat(hi_s)
    lo, hi = datetime.combine(lo_d, datetime.min.time(), UTC), datetime.combine(hi_d, datetime.min.time(), UTC)
    events = vevents(content_lines(open(path, "rb").read()))

    moved = {}
    for e in events:
        if "RECURRENCE-ID" in e:
            params, value = e["RECURRENCE-ID"][0]
            moved.setdefault(e["UID"][0][1].strip(), []).append(parse_time(value, params))

    rows = set()
    for e in events:
        if e.get("STATUS", [({}, "")])[0][1].strip().upper() == "CANCELLED":
            continue
        start = parse_time(e["DTSTART"][0][1], e["DTSTART"][0][0])
        all_day = not isinstance(start, datetime)
        if "DTEND" in e:
            end = parse_time(e["DTEND"][0][1], e["DTEND"][0][0])
            length = (as_naive(end) - as_naive(start)) if all_day else (end - start)
        elif "DURATION" in e:
            length = duration(e["DURATION"][0][1])
        else:
            length = timedelta(days=1) if all_day else timedelta(0)
        if all_day:
            length = max(length, timedelta(days=1))
        uid = e["UID"][0][1].strip()
        title = unescape(e.get("SUMMARY", [({}, "")])[0][1]).strip()

        starts = [start]
        if "RRULE" in e and "RECURRENCE-ID" not in e:
            first = as_naive(start)
            rset = rruleset()
            rset.rrule(rrulestr(fix_until(e["RRULE"][0][1], start), dtstart=first))
            rset.rdate(first)
            for r in times(e.get("RDATE", [])):
                rset.rdate(as_naive(r))
            for x in times(e.get("EXDATE", [])) + moved.get(uid, []):
                rset.exdate(as_naive(x))
            if all_day:
                window = (datetime.combine(lo_d, datetime.min.time()) - length, datetime.combine(hi_d, datetime.min.time()))
            else:
                window = (lo - length - timedelta(days=1), hi + timedelta(days=1))
            starts = rset.between(window[0], window[1], inc=True)

        for s in starts:
            if all_day:
                s_day = s.date() if isinstance(s, datetime) else s
                e_day = s_day + timedelta(days=length.days)
                if s_day < hi_d and e_day > lo_d:
                    rows.add((s_day.isoformat(), e_day.isoformat(), uid, title))
            else:
                end = s + length
                if s < hi and (end > lo or (end == s and s >= lo)):
                    fmt = lambda d: d.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
                    rows.add((fmt(s), fmt(end), uid, title))

    for start, end, uid, title in sorted(rows):
        print("\t".join([uid, start, end, title.replace("\t", " ").replace("\n", " ")]))


if __name__ == "__main__":
    main()

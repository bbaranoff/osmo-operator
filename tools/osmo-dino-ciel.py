#!/usr/bin/env python3
# osmo-dino-ciel.py - the sky of the dino, with the real NASA values.
#
# The model: a dino runs on the EQUATOR, due east, towards the rising sun, at
# a date BC, and time is ACCELERATED (by default one hour of sky per second,
# as in the game, whose day lasts 24 s). The Sun and the Moon are those of the
# JPL (NASA) - Horizons service, DE441 ephemeris - seen from the current
# position of the dino, which gains degrees of longitude by running. On the
# equator the bodies rise vertically; the TILT shows in the place where they
# rise: the Sun at `declinaison` degrees left (north) or right (south) of the
# road, the Moon up to 28.6 degrees (23.4 of obliquity + 5.1 of inclination of
# its orbit), and its ecliptic latitude says how far it departs from the
# path of the Sun.
#
# Sources:
#   horizons  https://ssd.jpl.nasa.gov/api/horizons.api  (default; requires
#             the network; the Moon exists there from 9999 BC to 9999 AD)
#   meeus     formulas of J. Meeus, Astronomical Algorithms (Sun ch. 25,
#             Moon ch. 47 truncated, ~0.3 degree) - offline fallback, no NASA.
#
# What the script does itself: the position of the dino (advancing longitude),
# sidereal time, the geocentric -> topocentric step (parallax of the Moon, up
# to 1 degree), azimuth/altitude, the frame of the dino (ahead/left/right/
# behind), the angle of the lit limb of the Moon, the Julian calendar for
# ancient dates (like Horizons before 15 October 1582).
#
# Examples:
#   osmo-dino-ciel.py                                # 9999 BC, 1 h/s
#   osmo-dino-ciel.py --date "BC 3000-06-21 04:00" --accel 600
#   osmo-dino-ciel.py --une-fois --json              # one instant, as JSON
#   osmo-dino-ciel.py --json --tick 0.5 > ciel.ndjson
#   osmo-dino-ciel.py --source meeus                 # without network
import argparse
import json
import math
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request

HORIZONS = "https://ssd.jpl.nasa.gov/api/horizons.api"
AU_KM = 149597870.7
R_TERRE_KM = 6378.137
DEG = math.pi / 180
J2000 = 2451545.0
JD_GREGORIEN = 2299160.5          # 1582-10-15 00:00: before, Julian calendar
JD_MIN_HORIZONS = -1931446.5      # BC 9999-Mar-16 00:00 UT (the Moon does not exist before)
MOIS = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet",
        "aout", "septembre", "octobre", "novembre", "decembre"]


# ---------------------------------------------------------------- calendar
def cal_vers_jd(y, m, d, frac=0.0, julien=None):
    """Calendar -> Julian day. y = astronomical year (0 = 1 BC).
    Julian before 15/10/1582 like Horizons, Gregorian after (or forced)."""
    a = (14 - m) // 12
    yy = y + 4800 - a
    mm = m + 12 * a - 3
    jdn_j = d + (153 * mm + 2) // 5 + 365 * yy + yy // 4 - 32083
    jdn_g = d + (153 * mm + 2) // 5 + 365 * yy + yy // 4 - yy // 100 + yy // 400 - 32045
    if julien is None:
        julien = (jdn_g - 0.5) < JD_GREGORIEN
    return (jdn_j if julien else jdn_g) - 0.5 + frac


def jd_vers_cal(jd):
    """Julian day -> (astronomical year, month, day, fraction of day)."""
    z = math.floor(jd + 0.5)
    f = jd + 0.5 - z
    if jd < JD_GREGORIEN:                       # Julian (integer division = floor)
        c = z + 32082
        d = (4 * c + 3) // 1461
        e = c - (1461 * d) // 4
        m = (5 * e + 2) // 153
        day = e - (153 * m + 2) // 5 + 1
        month = m + 3 - 12 * (m // 10)
        year = d - 4800 + m // 10
    else:
        a = z + 32044
        b = (4 * a + 3) // 146097
        c = a - (146097 * b) // 4
        d = (4 * c + 3) // 1461
        e = c - (1461 * d) // 4
        m = (5 * e + 2) // 153
        day = e - (153 * m + 2) // 5 + 1
        month = m + 3 - 12 * (m // 10)
        year = 100 * b + d - 4800 + m // 10
    return year, month, day, f


def date_fr(jd):
    y, m, d, f = jd_vers_cal(jd)
    h = f * 24
    an = f"an {1 - y} av. J.-C." if y <= 0 else f"an {y}"
    return f"{d} {MOIS[m - 1]} de l'{an}", f"{int(h):02d} h {int(h % 1 * 60):02d}"


def parse_date(s):
    """'BC 3000-06-21 04:00', '-2999-06-21', '3000 av. J.-C. 06-21', 'JD 625844.5',
    '2026-09-08T06:00'. BC years: 'BC n' or 'av' = year 1-n."""
    s = s.strip()
    m = re.match(r"^JD\s*([-+]?\d+(?:\.\d*)?)$", s, re.I)
    if m:
        return float(m.group(1))
    bc = False
    m = re.match(r"^(?:BC|B\.C\.|av(?:\.| J\.?-?C\.?|ant)?(?: J\.?-?C\.?)?)\s+(.*)$", s, re.I)
    if m:
        bc, s = True, m.group(1)
    m = re.match(r"^(?:(\d+)\s+av\.?\s*J\.?-?C\.?\s+)?([-+]?\d+)?-?(\d{1,2})-(\d{1,2})"
                 r"(?:[ T](\d{1,2})(?::(\d{2}))?(?::(\d{2}))?)?$", s)
    if not m:
        raise ValueError(f"date illisible : {s!r}")
    if m.group(1):
        bc, y = True, int(m.group(1))
    else:
        y = int(m.group(2))
    if bc:
        y = 1 - abs(y)
    mo, d = int(m.group(3)), int(m.group(4))
    frac = (int(m.group(5) or 0) + int(m.group(6) or 0) / 60 + int(m.group(7) or 0) / 3600) / 24
    return cal_vers_jd(y, mo, d, frac)


def horizons_date(jd):
    return f"JD {jd:.8f}"


# ---------------------------------------------------------------- geometry
def gmst_deg(jd_ut):
    """Greenwich mean sidereal time (Meeus 12.4), degrees."""
    t = (jd_ut - J2000) / 36525
    g = 280.46061837 + 360.98564736629 * (jd_ut - J2000) + 0.000387933 * t * t - t ** 3 / 38710000
    return g % 360


def radec_vec(ra, dec, r=1.0):
    return (r * math.cos(dec * DEG) * math.cos(ra * DEG),
            r * math.cos(dec * DEG) * math.sin(ra * DEG),
            r * math.sin(dec * DEG))


def norm(v):
    l = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2) or 1.0
    return (v[0] / l, v[1] / l, v[2] / l)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def wrap180(a):
    return (a + 180) % 360 - 180


def topocentrique(ra, dec, dist_km, jd_ut, lon_deg):
    """Geocentric body (RA/DEC of date, distance) seen from the equator at
    longitude lon: unit direction in the equatorial frame, plus the east /
    north / zenith axes of the observer, in that same frame."""
    theta = (gmst_deg(jd_ut) + lon_deg) * DEG            # local sidereal time
    obs = (R_TERRE_KM * math.cos(theta), R_TERRE_KM * math.sin(theta), 0.0)
    geo = radec_vec(ra, dec, dist_km)
    d = norm((geo[0] - obs[0], geo[1] - obs[1], geo[2] - obs[2]))
    est = (-math.sin(theta), math.cos(theta), 0.0)
    nord = (0.0, 0.0, 1.0)                                # on the equator, the pole is on the horizon
    zen = (math.cos(theta), math.sin(theta), 0.0)
    return d, est, nord, zen


def az_el(d, est, nord, zen):
    az = math.degrees(math.atan2(dot(d, est), dot(d, nord))) % 360
    el = math.degrees(math.asin(max(-1, min(1, dot(d, zen)))))
    return az, el


# ---------------------------------------------------------------- Horizons
class Horizons:
    """Apparent geocentric ephemeris of the JPL, in batches, with prefetch.
    Each line: jd, ra, dec, illum (0-1), delta (km), elong (deg), waxing,
    ecl_lon, ecl_lat."""
    NOM = "JPL Horizons (NASA, DE441)"

    def __init__(self, pas_min, lot=600):
        self.pas = max(1, int(round(pas_min)))
        self.lot = lot
        self.buf = {10: [], 301: []}
        self.fin = None
        self.lock = threading.Lock()
        self.prefetch = None

    def _requete(self, corps, jd0, jd1):
        q = {
            "format": "text", "COMMAND": f"'{corps}'", "OBJ_DATA": "'NO'",
            "MAKE_EPHEM": "'YES'", "EPHEM_TYPE": "'OBSERVER'", "CENTER": "'500@399'",
            "START_TIME": f"'{horizons_date(jd0)}'", "STOP_TIME": f"'{horizons_date(jd1)}'",
            "STEP_SIZE": f"'{self.pas}m'", "QUANTITIES": "'2,10,20,23,31'",
            "CAL_FORMAT": "'JD'", "ANG_FORMAT": "'DEG'", "CSV_FORMAT": "'YES'",
            "EXTRA_PREC": "'YES'",
        }
        url = HORIZONS + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)
        with urllib.request.urlopen(url, timeout=60) as r:
            txt = r.read().decode("utf-8", "replace")
        if "$$SOE" not in txt:
            err = [l for l in txt.splitlines() if "No ephemeris" in l or "rror" in l]
            raise RuntimeError("Horizons : " + (err[0].strip() if err else txt[:300]))
        rows = []
        for line in txt.split("$$SOE", 1)[1].split("$$EOE", 1)[0].splitlines():
            c = [x.strip() for x in line.split(",")]
            if len(c) < 12 or not c[0]:
                continue
            # JD, sol, lun, RA, DEC, Illu%, delta, deldot, S-O-T, /r, EcLon, EcLat
            rows.append((float(c[0]), float(c[3]), float(c[4]), float(c[5]) / 100,
                         float(c[6]) * AU_KM, float(c[8]), c[9].strip("/") == "T",
                         float(c[10]), float(c[11])))
        return rows

    def _charger(self, jd0):
        jd1 = jd0 + self.pas / 1440 * self.lot
        s = self._requete(10, jd0, jd1)
        m = self._requete(301, jd0, jd1)
        with self.lock:
            for k, rows in ((10, s), (301, m)):
                deja = {r[0] for r in self.buf[k]}
                self.buf[k].extend(r for r in rows if r[0] not in deja)
                self.buf[k].sort()
                # only the recent part is kept
                if len(self.buf[k]) > 4 * self.lot:
                    self.buf[k] = self.buf[k][-3 * self.lot:]
            self.fin = min(self.buf[10][-1][0], self.buf[301][-1][0])

    def _assurer(self, jd):
        if self.fin is None or jd > self.fin - self.pas / 1440:
            if self.prefetch and self.prefetch.is_alive():
                self.prefetch.join()
            if self.fin is None or jd > self.fin - self.pas / 1440:
                self._charger(jd if self.fin is None else self.fin)
        # prefetch when half of the batch has been consumed
        if (self.prefetch is None or not self.prefetch.is_alive()) and \
                jd > self.fin - self.pas / 1440 * self.lot / 2:
            self.prefetch = threading.Thread(target=self._charger, args=(self.fin,), daemon=True)
            self.prefetch.start()

    @staticmethod
    def _interp(rows, jd):
        # two bracketing lines, interpolation (RA/DEC through vectors)
        lo, hi = 0, len(rows) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if rows[mid][0] <= jd:
                lo = mid
            else:
                hi = mid
        a, b = rows[lo], rows[hi]
        t = 0.0 if b[0] == a[0] else max(0.0, min(1.0, (jd - a[0]) / (b[0] - a[0])))
        va, vb = radec_vec(a[1], a[2]), radec_vec(b[1], b[2])
        v = norm(tuple(va[i] + (vb[i] - va[i]) * t for i in range(3)))
        ra = math.degrees(math.atan2(v[1], v[0])) % 360
        dec = math.degrees(math.asin(max(-1, min(1, v[2]))))
        lin = lambda i: a[i] + (b[i] - a[i]) * t
        elon = (a[7] + wrap180(b[7] - a[7]) * t) % 360
        return dict(ra=ra, dec=dec, illum=lin(3), dist_km=lin(4), elong=lin(5),
                    croissante=a[6] if t < 0.5 else b[6], ecl_lon=elon, ecl_lat=lin(8))

    def at(self, jd):
        if jd < JD_MIN_HORIZONS:
            raise RuntimeError("Horizons n'a pas la Lune avant le 16 mars 9999 av. J.-C. "
                               "(--source meeus pour aller plus loin, sans la NASA)")
        self._assurer(jd)
        with self.lock:
            s, m = self.buf[10], self.buf[301]
            return self._interp(s, jd), self._interp(m, jd)


# ---------------------------------------------------------------- Meeus (fallback)
class Meeus:
    """Sun (ch. 25) and Moon (ch. 47, main terms), apparent geocentric,
    coordinates of date. No network. ~0.3 degree for the Moon; the polynomials
    drift at very ancient dates (a few degrees at -10000)."""
    NOM = "formules de Meeus (hors ligne, approximatif)"

    LR = [(0, 0, 1, 0, 6288774, -20905355), (2, 0, -1, 0, 1274027, -3699111),
          (2, 0, 0, 0, 658314, -2955968), (0, 0, 2, 0, 213618, -569925),
          (0, 1, 0, 0, -185116, 48888), (0, 0, 0, 2, -114332, -3149),
          (2, 0, -2, 0, 58793, 246158), (2, -1, -1, 0, 57066, -152138),
          (2, 0, 1, 0, 53322, -170733), (2, -1, 0, 0, 45758, -204586),
          (0, 1, -1, 0, -40923, -129620), (1, 0, 0, 0, -34720, 108743),
          (0, 1, 1, 0, -30383, 104755), (2, 0, 0, -2, 15327, 10321),
          (0, 0, 1, 2, -12528, 0), (0, 0, 1, -2, 10980, 79661),
          (4, 0, -1, 0, 10675, -34782), (0, 0, 3, 0, 10034, -23210),
          (4, 0, -2, 0, 8548, -21636), (2, 1, -1, 0, -7888, 24208),
          (2, 1, 0, 0, -6766, 30824), (1, 0, -1, 0, -5163, -8379),
          (1, 1, 0, 0, 4987, -16675), (2, -1, 1, 0, 4036, -12831),
          (2, 0, 2, 0, 3994, -10445), (4, 0, 0, 0, 3861, -11650),
          (2, 0, -3, 0, 3665, 14403), (0, 1, -2, 0, -2689, -7003),
          (2, 0, -1, 2, -2602, 0), (2, -1, -2, 0, 2390, 10056)]
    B = [(0, 0, 0, 1, 5128122), (0, 0, 1, 1, 280602), (0, 0, 1, -1, 277693),
         (2, 0, 0, -1, 173237), (2, 0, -1, 1, 55413), (2, 0, -1, -1, 46271),
         (2, 0, 0, 1, 32573), (0, 0, 2, 1, 17198), (2, 0, 1, -1, 9266),
         (0, 0, 2, -1, 8822), (2, -1, 0, -1, 8216), (2, 0, -2, -1, 4324),
         (2, 0, 1, 1, 4200), (2, 1, 0, -1, -3359), (2, -1, -1, 1, 2463),
         (2, -1, 0, 1, 2211), (2, -1, -1, -1, 2065), (0, 1, -1, -1, -1870),
         (4, 0, -1, -1, 1828), (0, 1, 0, 1, -1794)]

    def __init__(self, *_a, **_k):
        pass

    @staticmethod
    def _nutation_obliquite(t):
        om = (125.04452 - 1934.136261 * t) * DEG
        ls = (280.4665 + 36000.7698 * t) * DEG
        lm = (218.3165 + 481267.8813 * t) * DEG
        dpsi = (-17.20 * math.sin(om) - 1.32 * math.sin(2 * ls) - 0.23 * math.sin(2 * lm)
                + 0.21 * math.sin(2 * om)) / 3600
        deps = (9.20 * math.cos(om) + 0.57 * math.cos(2 * ls) + 0.10 * math.cos(2 * lm)
                - 0.09 * math.cos(2 * om)) / 3600
        eps0 = 23.4392911 - 0.01300417 * t - 1.639e-7 * t * t + 5.036e-7 * t ** 3
        return dpsi, eps0 + deps

    @staticmethod
    def _ecl_vers_eq(lon, lat, eps):
        l, b, e = lon * DEG, lat * DEG, eps * DEG
        ra = math.atan2(math.sin(l) * math.cos(e) - math.tan(b) * math.sin(e), math.cos(l))
        dec = math.asin(math.sin(b) * math.cos(e) + math.cos(b) * math.sin(e) * math.sin(l))
        return math.degrees(ra) % 360, math.degrees(dec)

    def _soleil(self, t, dpsi, eps):
        l0 = 280.46646 + 36000.76983 * t + 0.0003032 * t * t
        m = (357.52911 + 35999.05029 * t - 0.0001537 * t * t) * DEG
        c = ((1.914602 - 0.004817 * t - 0.000014 * t * t) * math.sin(m)
             + (0.019993 - 0.000101 * t) * math.sin(2 * m) + 0.000289 * math.sin(3 * m))
        nu = m + c * DEG
        e = 0.016708634 - 0.000042037 * t - 0.0000001267 * t * t
        r = 1.000001018 * (1 - e * e) / (1 + e * math.cos(nu))
        lon = (l0 + c + dpsi - 0.00569) % 360           # aberration + nutation
        ra, dec = self._ecl_vers_eq(lon, 0.0, eps)
        return dict(ra=ra, dec=dec, illum=1.0, dist_km=r * AU_KM, elong=0.0,
                    croissante=False, ecl_lon=lon, ecl_lat=0.0)

    def _lune(self, t, dpsi, eps):
        lp = 218.3164477 + 481267.88123421 * t - 0.0015786 * t * t + t ** 3 / 538841 - t ** 4 / 65194000
        d = 297.8501921 + 445267.1114034 * t - 0.0018819 * t * t + t ** 3 / 545868 - t ** 4 / 113065000
        m = 357.5291092 + 35999.0502909 * t - 0.0001536 * t * t + t ** 3 / 24490000
        mp = 134.9633964 + 477198.8675055 * t + 0.0087414 * t * t + t ** 3 / 69699 - t ** 4 / 14712000
        f = 93.2720950 + 483202.0175233 * t - 0.0036539 * t * t - t ** 3 / 3526000 + t ** 4 / 863310000
        a1, a2, a3 = 119.75 + 131.849 * t, 53.09 + 479264.290 * t, 313.45 + 481266.484 * t
        e = 1 - 0.002516 * t - 0.0000074 * t * t
        sl = sr = sb = 0.0
        for kd, km, kmp, kf, cl, cr in self.LR:
            arg = (kd * d + km * m + kmp * mp + kf * f) * DEG
            ee = e ** abs(km)
            sl += cl * ee * math.sin(arg)
            sr += cr * ee * math.cos(arg)
        for kd, km, kmp, kf, cb in self.B:
            arg = (kd * d + km * m + kmp * mp + kf * f) * DEG
            sb += cb * e ** abs(km) * math.sin(arg)
        sl += 3958 * math.sin(a1 * DEG) + 1962 * math.sin((lp - f) * DEG) + 318 * math.sin(a2 * DEG)
        sb += (-2235 * math.sin(lp * DEG) + 382 * math.sin(a3 * DEG) + 175 * math.sin((a1 - f) * DEG)
               + 175 * math.sin((a1 + f) * DEG) + 127 * math.sin((lp - mp) * DEG)
               - 115 * math.sin((lp + mp) * DEG))
        lon = (lp + sl / 1e6 + dpsi) % 360
        lat = sb / 1e6
        dist = 385000.56 + sr / 1000
        ra, dec = self._ecl_vers_eq(lon, lat, eps)
        return dict(ra=ra, dec=dec, dist_km=dist, ecl_lon=lon, ecl_lat=lat)

    def at(self, jd):
        t = (jd - J2000) / 36525
        dpsi, eps = self._nutation_obliquite(t)
        s = self._soleil(t, dpsi, eps)
        m = self._lune(t, dpsi, eps)
        # elongation, phase (Meeus ch. 48)
        psi = math.acos(max(-1, min(1, math.sin(s["dec"] * DEG) * math.sin(m["dec"] * DEG)
                                     + math.cos(s["dec"] * DEG) * math.cos(m["dec"] * DEG)
                                     * math.cos((s["ra"] - m["ra"]) * DEG))))
        i = math.atan2(s["dist_km"] * math.sin(psi), m["dist_km"] - s["dist_km"] * math.cos(psi))
        m["illum"] = (1 + math.cos(i)) / 2
        m["elong"] = math.degrees(psi)
        m["croissante"] = 0 < (m["ecl_lon"] - s["ecl_lon"]) % 360 < 180
        return s, m


# ---------------------------------------------------------------- the dino
def phase_nom(illum, croissante):
    if illum < 0.03:
        return "nouvelle lune"
    if illum > 0.97:
        return "pleine lune"
    if illum < 0.47:
        return "croissant" if croissante else "dernier croissant"
    if illum <= 0.53:
        return "premier quartier" if croissante else "dernier quartier"
    return "gibbeuse croissante" if croissante else "gibbeuse decroissante"


def cote(x):
    """x in degrees, positive = to the right of the dino (south, it runs east)."""
    if abs(x) < 0.5:
        return "droit devant"
    return f"{abs(x):.1f} deg a {'droite (sud)' if x > 0 else 'gauche (nord)'}"


def calcul(eph, jd, lon):
    s, m = eph.at(jd)
    ds, est, nord, zen = topocentrique(s["ra"], s["dec"], s["dist_km"], jd, lon)
    dm, _, _, _ = topocentrique(m["ra"], m["dec"], m["dist_km"], jd, lon)
    sud = (-nord[0], -nord[1], -nord[2])
    out = {}
    for nom, d, geo in (("soleil", ds, s), ("lune", dm, m)):
        az, el = az_el(d, est, nord, zen)
        devant, droite = dot(d, est), dot(d, sud)
        lateral = math.degrees(math.atan2(droite, devant))       # 0 ahead, +90 right, 180 behind
        out[nom] = dict(az=round(az, 3), hauteur=round(el, 3), lateral=round(lateral, 2),
                        devant=devant > 0, ra=round(geo["ra"], 4), dec=round(geo["dec"], 4),
                        ecl_lon=round(geo["ecl_lon"], 4), ecl_lat=round(geo["ecl_lat"], 4),
                        dist_km=round(geo["dist_km"], 1),
                        # on the equator, a body rises at azimuth 90 - dec:
                        # dec > 0 => left (north) of the due-east road.
                        lever_lateral=round(-geo["dec"], 2))
    # lit limb of the Moon: direction of the Sun seen from the Moon,
    # projected on the sky around it. 0 = lit from the top, 90 = from the
    # right of the dino, -90 = from the left, 180 = from the bottom.
    haut = norm(tuple(zen[i] - dot(zen, dm) * dm[i] for i in range(3)))
    droite = cross(dm, haut)          # to the right when looking at the Moon (looking up)
    vers_soleil = norm(tuple(ds[i] * s["dist_km"] - dm[i] * m["dist_km"] for i in range(3)))
    limbe = math.degrees(math.atan2(dot(vers_soleil, droite), dot(vers_soleil, haut)))
    out["lune"].update(illum=round(m["illum"], 4), elong=round(m["elong"], 3),
                       croissante=bool(m["croissante"]),
                       phase=phase_nom(m["illum"], m["croissante"]), limbe=round(limbe, 1))
    out["nuit"] = out["soleil"]["hauteur"] < -6
    return out


def texte(jd, lon, km, accel, src, c):
    d, h = date_fr(jd)
    hl = (jd + lon / 360 + 0.5) % 1 * 24                         # local mean solar time
    s, m = c["soleil"], c["lune"]
    lines = [
        f"{d}, {h} UT  ·  heure locale {int(hl):02d} h {int(hl % 1 * 60):02d}  ·  x{accel:g}",
        f"le dino : equateur, longitude {lon:.2f} deg E, {km:.1f} km parcourus, route plein est",
        f"Soleil : hauteur {s['hauteur']:+6.1f}  azimut {s['az']:6.1f}  {'devant' if s['devant'] else 'derriere'}, {cote(s['lateral'] if s['devant'] else wrap180(180 - s['lateral']))}"
        f"  ·  se leve {cote(s['lever_lateral'])} (declinaison {s['dec']:+.1f})",
        f"Lune   : hauteur {m['hauteur']:+6.1f}  azimut {m['az']:6.1f}  {'devant' if m['devant'] else 'derriere'}, {cote(m['lateral'] if m['devant'] else wrap180(180 - m['lateral']))}"
        f"  ·  se leve {cote(m['lever_lateral'])} (declinaison {m['dec']:+.1f})",
        f"         {m['phase']}, eclairee a {m['illum'] * 100:.0f} %, elongation {m['elong']:.0f} deg,"
        f" limbe eclaire vers {m['limbe']:+.0f} deg (0 = haut, +90 = droite)",
        f"         latitude ecliptique {m['ecl_lat']:+.2f} deg (inclinaison de l'orbite : jusqu'a 5,1), distance {m['dist_km'] / 1000:.0f} mille km",
        f"{'nuit' if c['nuit'] else 'jour'}  ·  source : {src}",
    ]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="le ciel du dino, aux valeurs de la NASA (JPL Horizons)")
    ap.add_argument("--date", default="BC 9999-03-16 04:00",
                    help="depart : 'BC 3000-06-21 04:00', '-2999-06-21', 'JD 625844.5', ISO (defaut : le plus vieux ciel qu'Horizons connaisse)")
    ap.add_argument("--lon", type=float, default=0.0, help="longitude de depart en deg est (defaut 0)")
    ap.add_argument("--vitesse", type=float, default=10.0, help="vitesse du dino en m/s, vers l'est (defaut 10)")
    ap.add_argument("--accel", type=float, default=3600.0, help="acceleration du temps (defaut 3600 : une heure par seconde, la journee de 24 s du jeu)")
    ap.add_argument("--tick", type=float, default=1.0, help="secondes reelles entre deux affichages (defaut 1)")
    ap.add_argument("--duree", type=float, default=0.0, help="secondes reelles avant de s'arreter (0 = sans fin)")
    ap.add_argument("--une-fois", action="store_true", help="un seul instant, puis quitte")
    ap.add_argument("--json", action="store_true", help="une ligne JSON par tick (pour la page du dino)")
    ap.add_argument("--source", choices=("auto", "horizons", "meeus"), default="auto")
    a = ap.parse_args()

    jd0 = parse_date(a.date)
    pas_min = a.accel * a.tick / 60
    eph = None
    if a.source in ("auto", "horizons"):
        try:
            eph = Horizons(pas_min)
            eph.at(jd0)
        except Exception as e:                                   # network, date outside DE441...
            if a.source == "horizons":
                sys.exit(f"[ciel] {e}")
            print(f"[ciel] Horizons indisponible ({e}) : repli sur Meeus", file=sys.stderr)
            eph = None
    if eph is None:
        eph = Meeus()

    tty = sys.stdout.isatty() and not a.json
    t0 = time.monotonic()
    n = 0
    try:
        while True:
            reel = time.monotonic() - t0
            jd = jd0 + reel * a.accel / 86400
            m_parc = a.vitesse * reel * a.accel
            lon = (a.lon + m_parc / 111319.49 + 180) % 360 - 180   # 1 deg = 111.3 km on the equator
            c = calcul(eph, jd, lon)
            if a.json:
                d, h = date_fr(jd)
                c.update(jd=round(jd, 6), date=f"{d}, {h} UT", lon=round(lon, 4), km=round(m_parc / 1000, 2),
                         accel=a.accel, source=eph.NOM)
                print(json.dumps(c, ensure_ascii=False), flush=True)
            else:
                out = texte(jd, lon, m_parc / 1000, a.accel, eph.NOM, c)
                if tty and n:
                    out = "\x1b[7A\x1b[J" + out
                print(out, flush=True)
            n += 1
            if a.une_fois or (a.duree and reel >= a.duree):
                break
            time.sleep(max(0.0, a.tick - ((time.monotonic() - t0) % a.tick)))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

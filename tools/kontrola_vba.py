#!/usr/bin/env python3
"""Statická kontrola VBA modulov balíka Access (access/moduly/*.bas) na chyby, ktoré Access hlási až pri Ladenie > Kompilovať.
Len štandardná knižnica. VBA tu nespúšťame, kontroly sú konzervatívne: radšej nahlásia viac než prehliadnu chybu.

Použitie (z koreňa repozitára):
    python3 -I tools/kontrola_vba.py                 # skontroluje access/moduly, kód 1 = nájdená chyba
    python3 -I tools/kontrola_vba.py --varovania     # vypíše aj varovania (možné chyby, ktoré kompilátor nemusí hlásiť)

Kontroluje (v zátvorke chyba, ktorú by Access hlásil):
  1. zatienenie: lokálna premenná alebo parameter má rovnaké meno (VBA nerozlišuje veľkosť písmen) ako funkcia, ktorú tá istá
     procedúra volá (Expected array / Wrong number of arguments / Type mismatch);
  2. nedeklarovaná premenná pri Option Explicit (Variable not defined);
  3. volanie  modul.Meno  na neexistujúci alebo súkromný člen (Method or data member not found);
  4. nesprávny počet argumentov pri volaní procedúry z balíka (Wrong number of arguments);
  5. argument odovzdaný ByRef s iným deklarovaným typom než parameter (ByRef argument type mismatch);
  6. nespárované bloky If / For / Do / With / Select / procedúry (Block If without End If, Next without For, ...);
  7. súbor bez Option Explicit.
Nič nemení.
"""
import argparse
import os
import re
import sys

sys.dont_write_bytecode = True
KOREN = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# ------------------------------------------------------------------ pomocné
KLUCOVE = set("""
and as boolean byref byte byval call case const currency date declare dim do double each else elseif empty end enum eqv erase
error exit false for friend function get global gosub goto if imp implements in integer is let like long loop lset me mod new next
not nothing null on option optional or paramarray preserve private property public raiseevent redim rem resume return rset select set
single static step stop string sub then to true type typeof until variant wend while with withevents xor object any
open close input output append binary random access shared lock read write print line seek put len lenb name kill
""".split())

VSTAVANE = set("""
abs array asc ascb ascw atn cbool cbyte ccur cdate cdbl cdec choose chr chrb chrw cint clng csng cstr curdir cvar cverr
date dateadd datediff datepart dateserial datevalue day ddb dir doevents environ eof err error exp fileattr filecopy filedatetime filelen fix
format formatcurrency formatdatetime formatnumber formatpercent freefile fv getattr hex hour iif input inputb inputbox instr instrb instrrev int ipmt
irr isarray isdate isempty iserror ismissing isnull isnumeric isobject join lbound lcase left leftb len loc lof log ltrim mid midb minute mkdir
month monthname msgbox now nper npv oct partition pmt ppmt pv qbcolor rate replace rgb right rightb rmdir rnd round rtrim second seek sgn shell
sin sln space spc split sqr str strcomp strconv string strreverse switch syd tab tan time timer timeserial timevalue trim typename ubound ucase
val vartype weekday weekdayname year
application currentdb currentproject currentuser docmd debug forms reports screen access dbengine workspaces
deletecontrol deletereportcontrol createcontrol createreportcontrol createform createreport creategrouplevel syscmd strptr varptr objptr
dlookup dcount dsum dmax dmin davg dfirst dlast nz eval createobject getobject trace tempvars
dao adodb scripting vba excel word outlook office stdole
""".split())

PREDPONY_KONSTANT = re.compile(r"^(vb|db|ac|ad[A-Z]|xl|mso|fso|wd|ol|ado|dbe|rpt|ct)[A-Za-z]", re.I)
POVOLENE_PREDPONY = ("vb", "db", "ac", "xl", "mso", "wd", "ol", "ado", "dbe")

RE_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class Chyba:
    def __init__(self, uroven, modul, riadok, text):
        self.uroven, self.modul, self.riadok, self.text = uroven, modul, riadok, text

    def __str__(self):
        return "%s %s:%s  %s" % (self.uroven, self.modul, self.riadok, self.text)


def cisti_riadok(r):
    """Nahradí obsah reťazcov prázdnymi úvodzovkami a odstráni komentár. Vráti text bez koncových medzier."""
    out = []
    v_ret = False
    i, n = 0, len(r)
    while i < n:
        c = r[i]
        if v_ret:
            if c == '"':
                if i + 1 < n and r[i + 1] == '"':
                    i += 2
                    continue
                v_ret = False
                out.append('"')
        else:
            if c == '"':
                v_ret = True
                out.append('"')
            elif c == "'":
                break
            else:
                out.append(c)
        i += 1
    return "".join(out).rstrip()


def logicke_riadky(text):
    """[(cislo_prveho_fyzickeho_riadka, ciste_logicke_riadky)], spojí pokračovania ' _'."""
    vysl, buf, start = [], [], None
    for no, r in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
        c = cisti_riadok(r)
        if start is None:
            start = no
        if c.endswith(" _") or c == "_":
            buf.append(c[:-1])
            continue
        buf.append(c)
        spojeny = " ".join(x.strip() for x in buf).strip()
        if spojeny:
            vysl.append((start, spojeny))
        buf, start = [], None
    return vysl


def deli_ciarky(s):
    """Rozdelí na najvyššej úrovni podľa čiarok (zátvorky a reťazce nerozbíja). Prázdne polia ponechá."""
    out, d, cur, v_ret = [], 0, [], False
    for c in s:
        if c == '"':
            v_ret = not v_ret
        if not v_ret:
            if c == "(":
                d += 1
            elif c == ")":
                d -= 1
            elif c == "," and d == 0:
                out.append("".join(cur).strip())
                cur = []
                continue
        cur.append(c)
    out.append("".join(cur).strip())
    return out


def parna_zatvorka(s, i):
    """Index zodpovedajúcej ')' pre '(' na pozícii i alebo -1."""
    d, v_ret = 0, False
    for j in range(i, len(s)):
        c = s[j]
        if c == '"':
            v_ret = not v_ret
        if v_ret:
            continue
        if c == "(":
            d += 1
        elif c == ")":
            d -= 1
            if d == 0:
                return j
    return -1


def norm_typ(t):
    if not t:
        return "variant"
    t = t.strip().lower()
    for p in ("dao.", "vba.", "scripting.", "access.", "adodb."):
        if t.startswith(p):
            t = t[len(p):]
    return {"object": "object"}.get(t, t)


# ------------------------------------------------------------------ rozbor modulu
RE_PROC = re.compile(r"^(?:(Public|Private|Friend)\s+)?(?:Static\s+)?(Function|Sub|Property\s+Get|Property\s+Let|Property\s+Set)\s+([A-Za-z_]\w*)\s*(.*)$", re.I)
RE_DECL = re.compile(r"^((?:Public|Private|Global)\s+Const|(?:Public|Private|Global)\s+Static|Dim|Static|Private|Public|Global|Const)\s+(.*)$", re.I)
RE_PRM = re.compile(r"^(Optional\s+)?(ByVal\s+|ByRef\s+)?(ParamArray\s+)?([A-Za-z_]\w*)\s*(\(\s*\))?\s*(?:As\s+(?:New\s+)?([\w.]+))?\s*(?:=\s*(.*))?$", re.I)
RE_VAR = re.compile(r"^(?:WithEvents\s+)?([A-Za-z_]\w*)\s*(\(.*?\))?\s*(?:As\s+(?:New\s+)?([\w.]+)(?:\s*\*\s*\w+)?)?\s*(?:=\s*(.*))?$", re.I)


class Proc:
    def __init__(self, nazov, druh, verejna, riadok):
        self.nazov, self.druh, self.verejna, self.riadok = nazov, druh, verejna, riadok
        self.params = []   # dict(name, optional, byval, paramarray, array, typ)
        self.navrat = None
        self.lokalne = {}  # lower -> dict(name, typ, array, riadok)
        self.telo = []     # [(riadok, text)]


class Modul:
    def __init__(self, nazov, cesta):
        self.nazov, self.cesta = nazov, cesta
        self.procs = {}       # lower -> Proc (prvá definícia; Property Get/Let majú rovnaké meno)
        self.premenne = {}    # lower -> dict(name, typ, array, verejna, konst)
        self.enum = set()
        self.option_explicit = False
        self.chyby = []
        self.vsetky_procs = []


def parsuj_parametre(s, proc, mod, no):
    s = s.strip()
    if not s:
        return
    for p in deli_ciarky(s):
        m = RE_PRM.match(p.strip())
        if not m:
            mod.chyby.append(Chyba("CHYBA", mod.nazov, no, "nepodarilo sa prečítať parameter '%s' procedúry %s" % (p, proc.nazov)))
            continue
        opt, bv, pa, nm, arr, typ, _ = m.groups()
        proc.params.append(dict(name=nm, optional=bool(opt), byval=bool(bv and bv.strip().lower() == "byval"), paramarray=bool(pa),
                                array=bool(arr), typ=norm_typ(typ) if typ else "variant", typ_explicitny=bool(typ)))


def pridaj_deklaracie(dec_text, kam, no, mod, verejna=False, konst=False):
    for cast in deli_ciarky(dec_text):
        if not cast:
            continue
        m = RE_VAR.match(cast)
        if not m:
            mod.chyby.append(Chyba("CHYBA", mod.nazov, no, "nepodarilo sa prečítať deklaráciu '%s'" % cast))
            continue
        nm, arr, typ, _ = m.groups()
        kam[nm.lower()] = dict(name=nm, typ=norm_typ(typ) if typ else ("variant" if not konst else "const"), array=bool(arr), verejna=verejna, konst=konst, riadok=no)


def nacitaj_modul(cesta):
    nazov = os.path.splitext(os.path.basename(cesta))[0]
    mod = Modul(nazov, cesta)
    with open(cesta, "rb") as f:
        text = f.read().decode("utf-8-sig")
    riadky = logicke_riadky(text)
    cur = None
    v_enum = v_typ = False
    for no, r in riadky:
        low = r.lower()
        if low.startswith("attribute "):
            continue
        if low.startswith("option explicit"):
            mod.option_explicit = True
            continue
        if low.startswith("option "):
            continue
        if cur is None:
            m = re.match(r"^(?:(?:Public|Private|Friend)\s+)?Enum\s+(\w+)", r, re.I)
            if m:
                v_enum = True
                continue
            if v_enum:
                if re.match(r"^End\s+Enum", r, re.I):
                    v_enum = False
                else:
                    mm = RE_IDENT.match(r)
                    if mm:
                        mod.enum.add(mm.group(0).lower())
                continue
            if re.match(r"^(?:(?:Public|Private)\s+)?Type\s+\w+", r, re.I):
                v_typ = True
                continue
            if v_typ:
                if re.match(r"^End\s+Type", r, re.I):
                    v_typ = False
                continue
            m = re.match(r"^(?:(?:Public|Private)\s+)?Declare\s+(?:PtrSafe\s+)?(?:Function|Sub)\s+(\w+)", r, re.I)
            if m:
                p = Proc(m.group(1), "declare", True, no)
                mod.procs[m.group(1).lower()] = p
                continue
            m = RE_PROC.match(r)
            if m:
                vis, druh, nm, zvysok = m.groups()
                cur = Proc(nm, druh.split()[0].lower() if druh.lower().startswith("property") is False else "property", (vis or "public").lower() != "private", no)
                zvysok = zvysok.strip()
                if zvysok.startswith("("):
                    k = parna_zatvorka(zvysok, 0)
                    if k < 0:
                        mod.chyby.append(Chyba("CHYBA", mod.nazov, no, "nespárovaná zátvorka v hlavičke %s" % nm))
                        k = len(zvysok) - 1
                    parsuj_parametre(zvysok[1:k], cur, mod, no)
                    zvysok = zvysok[k + 1:].strip()
                ma = re.match(r"^As\s+([\w.]+)", zvysok, re.I)
                if ma:
                    cur.navrat = norm_typ(ma.group(1))
                if nm.lower() not in mod.procs:
                    mod.procs[nm.lower()] = cur
                mod.vsetky_procs.append(cur)
                continue
            m = RE_DECL.match(r)
            if m:
                kw, zv = m.groups()
                kwl = kw.lower()
                pridaj_deklaracie(zv, mod.premenne, no, mod, verejna=kwl.startswith(("public", "global")), konst="const" in kwl)
                continue
            # iné riadky na úrovni modulu (napr. Implements) ignorujeme
            continue
        # sme vo vnútri procedúry
        if re.match(r"^End\s+(Function|Sub|Property)\b", r, re.I):
            cur.telo.append((no, r))
            cur = None
            continue
        for cast, _bl in prikazy(r):
            m = RE_DECL.match(cast)
            if m and not re.match(r"^(Public|Private|Global)\b", cast, re.I):
                kw, zv = m.groups()
                pridaj_deklaracie(zv, cur.lokalne, no, mod, konst="const" in kw.lower())
        cur.telo.append((no, r))
    if cur is not None:
        mod.chyby.append(Chyba("CHYBA", mod.nazov, cur.riadok, "procedúra %s nemá End %s" % (cur.nazov, cur.druh)))
    return mod


# ------------------------------------------------------------------ rozklad príkazov
def prikazy(r):
    """Rozdelí logický riadok na jednotlivé príkazy (dvojbodka, jednoriadkové If ... Then ... Else ...). Vráti zoznam (text, je_blokovy_if)."""
    r = r.replace(":=", "\x01")
    # označenie: 'Navestie:'
    if re.match(r"^[A-Za-z_]\w*:\s*$", r):
        return []
    casti, d, cur, v_ret = [], 0, [], False
    for c in r:
        if c == '"':
            v_ret = not v_ret
        if not v_ret:
            if c == "(":
                d += 1
            elif c == ")":
                d -= 1
            elif c == ":" and d == 0:
                casti.append("".join(cur))
                cur = []
                continue
        cur.append(c)
    casti.append("".join(cur))
    vysl = []
    for c in casti:
        c = c.replace("\x01", ":=").strip()
        if not c:
            continue
        vysl.extend(rozloz_if(c))
    return vysl


def rozloz_if(c):
    m = re.match(r"^(ElseIf|If)\s+(.*)$", c, re.I)
    if not m:
        m2 = re.match(r"^Else\s+(.+)$", c, re.I)
        if m2:
            return [("Else", False)] + rozloz_if(m2.group(1))
        return [(c, False)]
    kw, zvysok = m.groups()
    # posledné 'Then' na najvyššej úrovni
    pos = najdi_then(zvysok)
    if pos < 0:
        return [(c, False)]  # chýba Then (hlási kontrola blokov)
    pod = zvysok[pos + 4:].strip()
    podm = zvysok[:pos].strip()
    if not pod:
        return [("%s %s Then" % (kw, podm), kw.lower() == "if")]
    # jednoriadkové If: telo môže mať Else
    cast_else = najdi_else(pod)
    if cast_else >= 0:
        a, b = pod[:cast_else].strip(), pod[cast_else + 4:].strip()
        out = [("%s %s Then" % (kw, podm), False)]
        if a:
            out.extend(rozloz_if(a))
        if b:
            out.extend(rozloz_if(b))
        return out
    return [("%s %s Then" % (kw, podm), False)] + rozloz_if(pod)


def najdi_then(s):
    d, v_ret = 0, False
    for m in re.finditer(r'"|\(|\)|\bThen\b', s, re.I):
        t = m.group(0)
        if t == '"':
            v_ret = not v_ret
        elif v_ret:
            continue
        elif t == "(":
            d += 1
        elif t == ")":
            d -= 1
        elif d == 0:
            # skutočne posledný Then (za Then môže byť príkaz); prvý na najvyššej úrovni stačí
            return m.start()
    return -1


def najdi_else(s):
    d, v_ret = 0, False
    for m in re.finditer(r'"|\(|\)|\bElse\b', s, re.I):
        t = m.group(0)
        if t == '"':
            v_ret = not v_ret
        elif v_ret:
            continue
        elif t == "(":
            d += 1
        elif t == ")":
            d -= 1
        elif d == 0:
            return m.start()
    return -1


# ------------------------------------------------------------------ kontrola blokov
def kontrola_blokov(mod, proc):
    zas = []  # (druh, premenna, riadok)

    def chyba(no, t):
        mod.chyby.append(Chyba("CHYBA", mod.nazov, no, "%s (v %s)" % (t, proc.nazov)))

    for no, r in proc.telo:
        for p, blokovy in prikazy(r):
            if blokovy:
                zas.append(("if", None, no))
                continue
            l = p.lower()
            if re.match(r"^if\b", l) and not l.endswith(" then") and " then " not in l + " " and not re.search(r"\bthen\b", l):
                chyba(no, "If bez Then: %s" % p)
                continue
            m = re.match(r"^For\s+(?:Each\s+)?([A-Za-z_]\w*)", p, re.I)
            if m:
                zas.append(("for", m.group(1).lower(), no))
                continue
            if re.match(r"^Do\b", p, re.I):
                zas.append(("do", None, no))
                continue
            if re.match(r"^While\b", p, re.I):
                zas.append(("while", None, no))
                continue
            if re.match(r"^With\b", p, re.I):
                zas.append(("with", None, no))
                continue
            if re.match(r"^Select\s+Case\b", p, re.I):
                zas.append(("select", None, no))
                continue
            if re.match(r"^(ElseIf|Else)\b", p, re.I):
                if not zas or zas[-1][0] != "if":
                    chyba(no, "%s bez If" % p.split()[0])
                continue
            if re.match(r"^Case\b", p, re.I):
                if not zas or zas[-1][0] != "select":
                    chyba(no, "Case mimo Select Case")
                continue
            m = re.match(r"^End\s+(If|With|Select)\b", p, re.I)
            if m:
                druh = m.group(1).lower()
                if not zas or zas[-1][0] != druh:
                    chyba(no, "End %s bez zodpovedajúceho začiatku (otvorené: %s)" % (m.group(1), zas[-1][0] if zas else "nič"))
                else:
                    zas.pop()
                continue
            if re.match(r"^Loop\b", p, re.I):
                if not zas or zas[-1][0] != "do":
                    chyba(no, "Loop bez Do")
                else:
                    zas.pop()
                continue
            if re.match(r"^Wend\b", p, re.I):
                if not zas or zas[-1][0] != "while":
                    chyba(no, "Wend bez While")
                else:
                    zas.pop()
                continue
            m = re.match(r"^Next\b\s*(.*)$", p, re.I)
            if m:
                mena = [x.strip().lower() for x in m.group(1).split(",") if x.strip()] or [None]
                for nm in mena:
                    if not zas or zas[-1][0] != "for":
                        chyba(no, "Next bez For")
                        break
                    if nm is not None and zas[-1][1] != nm:
                        chyba(no, "Next %s nezodpovedá For %s (riadok %d)" % (nm, zas[-1][1], zas[-1][2]))
                    zas.pop()
                continue
    for druh, nm, no in zas:
        chyba(no, "blok %s%s nie je ukončený" % (druh, " " + nm if nm else ""))


# ------------------------------------------------------------------ kontrola identifikátorov
def tokeny_vyrazu(p):
    """[(identifikator, predchadzajuci_znak, nasledujuci_neprazdny_znak, pozicia_konca)] bez čísel; reťazce sú už vyprázdnené."""
    out = []
    for m in RE_IDENT.finditer(p):
        s, e = m.span()
        # čísla typu 1E5, &H1F, 12L: ak token začína tesne za číslicou alebo &, preskoč
        if s > 0 and (p[s - 1].isdigit() or p[s - 1] in "#"):
            continue
        if s > 0 and p[s - 1] == "&" and re.match(r"^[HhOo][0-9A-Fa-f]+$", m.group(0)):
            continue
        if s > 1 and p[s - 1] == "&" and p[s - 2] in "0123456789":
            continue
        pred = p[s - 1] if s > 0 else ""
        # preskoč medzery pred tokenom, aby sa našlo '.' alebo '!' aj pri 'x . y' (zriedkavé)
        j = s - 1
        while j >= 0 and p[j] == " ":
            j -= 1
        pred_nm = p[j] if j >= 0 else ""
        k = e
        while k < len(p) and p[k] == " ":
            k += 1
        nasl = p[k] if k < len(p) else ""
        nasl2 = p[k:k + 2] if k < len(p) else ""
        out.append((m.group(0), pred_nm, nasl, e, nasl2))
    return out


def je_vstavane(nm):
    l = nm.lower()
    if l in KLUCOVE or l in VSTAVANE:
        return True
    if l.startswith(POVOLENE_PREDPONY) and len(l) > 2 and nm[2:3].isupper():
        return True
    if l.startswith("vb") and len(l) > 2:
        return True
    return False


class Svet:
    def __init__(self, moduly):
        self.moduly = {m.nazov.lower(): m for m in moduly}
        self.verejne = {}  # meno -> [(modul, objekt)]
        for m in moduly:
            for k, p in m.procs.items():
                if p.verejna:
                    self.verejne.setdefault(k, []).append((m, p))
            for k, v in m.premenne.items():
                if v["verejna"]:
                    self.verejne.setdefault(k, []).append((m, v))
            for e in m.enum:
                self.verejne.setdefault(e, []).append((m, "enum"))


def kontrola_procedury(svet, mod, proc, varovania, dovod_ticho):
    chyby = mod.chyby
    lokal = dict(proc.lokalne)
    for p in proc.params:
        lokal.setdefault(p["name"].lower(), dict(name=p["name"], typ=p["typ"], array=p["array"], riadok=proc.riadok, parameter=True, byval=p["byval"]))
    nazov_l = proc.nazov.lower()

    def zname_meno(l):
        return l in lokal or l in mod.premenne or l in mod.procs or l in svet.verejne or l in mod.enum or l in svet.moduly or l == nazov_l

    # for each / for premenne a deklarácie pomocou For Each tiež musia byť deklarované: kontroluje sa nižšie ako použitie
    volane_nazvy = set()
    zamenene = []

    for no, r in proc.telo:
        for p, _bl in prikazy(r):
            if re.match(r"^(Dim|Static|Const)\b", p, re.I):
                continue
            if re.match(r"^(On\s+Error|Resume|GoTo|GoSub|Exit|End\b|Option|Attribute|Debug\.|Randomize|Stop)", p, re.I):
                # 'On Error GoTo Chyba' a pod.: bez analýzy identifikátorov (návestia)
                if re.match(r"^(On\s+Error\s+GoTo\s+\w+|On\s+Error\s+Resume\s+Next|Resume\s+\w+|GoTo\s+\w+|Exit\s+\w+|End\s+\w+|End|Resume|Stop|Randomize)\s*$", p, re.I):
                    continue
            p2 = p
            # Open ... For Input As #n | Close #n | Print #n | Line Input #n | Put/Get #
            mm = re.match(r"^(Open|Close|Print|Write|Line\s+Input|Input|Get|Put|Seek|Lock|Unlock|Name)\b(.*)$", p2, re.I)
            if mm and mm.group(1).lower() in ("open", "close", "print", "write", "line input", "input", "get", "put", "seek", "name", "lock", "unlock") and not re.match(r"^(Print|Write|Input|Get|Put|Name|Open|Close|Seek)\s*[=(\.]", p2, re.I):
                p2 = re.sub(r"\b(For|Input|Output|Append|Binary|Random|As|Access|Read|Write|Shared|Lock|Len)\b", " ", mm.group(2), flags=re.I)
                p2 = re.sub(r"#\s*\w+", " ", p2)
                if mm.group(1).lower() == "name":
                    p2 = re.sub(r"\bAs\b", " ", p2, flags=re.I)
            # cieľ priradenia / deklarácie typov
            p2 = re.sub(r"\bAs\s+(?:New\s+)?[A-Za-z_][\w.]*", " ", p2, flags=re.I)
            p2 = re.sub(r"\bNew\s+[A-Za-z_][\w.]*", " ", p2, flags=re.I)
            p2 = re.sub(r"\bGoTo\s+\w+", " ", p2, flags=re.I)
            p2 = re.sub(r"\bTypeOf\s+(\w+)\s+Is\s+[A-Za-z_][\w.]*", r" \1 ", p2, flags=re.I)
            p2 = re.sub(r"^\s*(ReDim)\s+(Preserve\s+)?", "", p2, flags=re.I)
            toks = tokeny_vyrazu(p2)
            for nm, pred, nasl, end, nasl2 in toks:
                l = nm.lower()
                if pred in (".", "!"):
                    continue  # člen objektu alebo kľúč recordsetu
                if nasl2 == ":=":
                    continue  # pomenovaný argument
                if je_vstavane(nm) and l not in lokal and l not in mod.premenne and l not in mod.procs:
                    continue
                if l in lokal or l in mod.premenne or l in mod.procs or l in svet.verejne or l in mod.enum or l in svet.moduly or l == nazov_l:
                    continue
                if PREDPONY_KONSTANT.match(nm) and l.startswith(("db", "ac", "xl", "mso", "wd", "ol", "ado", "dbe", "vb", "fso", "rpt")):
                    continue
                if mod.option_explicit:
                    chyby.append(Chyba("CHYBA", mod.nazov, no, "nedeklarovaná premenná alebo neznáma funkcia '%s' (v %s): %s" % (nm, proc.nazov, p.strip()[:90])))
            # zatienenie a volania
            for nm, pred, nasl, end, nasl2 in toks:
                if pred in (".", "!"):
                    continue
                l = nm.lower()
                if nasl == "(":
                    volane_nazvy.add((l, no))
            kontrola_volani(svet, mod, proc, lokal, no, p, chyby, varovania)
    # zatienenie funkcie lokálnou premennou, ktorá sa volá ako funkcia
    dost = set()
    for l, no in sorted(volane_nazvy):
        if l == nazov_l:
            continue
        loc = lokal.get(l)
        if loc is None:
            continue
        cudzia = None
        if l in mod.procs and mod.procs[l].druh in ("function", "sub", "declare"):
            cudzia = (mod, mod.procs[l])
        elif l in svet.verejne:
            for m2, o in svet.verejne[l]:
                if hasattr(o, "druh"):
                    cudzia = (m2, o)
                    break
        if cudzia is None or (l, "x") in dost:
            continue
        if loc.get("array"):
            continue  # pole: l(i) je indexovanie, nie volanie
        dost.add((l, "x"))
        typ = loc.get("typ")
        uroven = "CHYBA" if typ not in ("variant", "object") else "VAROVANIE"
        kde = "modul %s" % cudzia[0].nazov if cudzia[0] is not mod else "tento modul"
        chyby_alebo = chyby if uroven == "CHYBA" else varovania
        chyby_alebo.append(Chyba(uroven, mod.nazov, no, "premenná '%s' (%s) v %s zatieňuje funkciu %s (%s), ktorú tá istá procedúra volá; VBA nerozlišuje veľkosť písmen. Premenujte premennú" % (loc["name"], typ, proc.nazov, cudzia[1].nazov, kde)))


def najdi_cielovu_proceduru(svet, mod, qual, meno, lokal):
    """Vráti (modul, proc) alebo (None, None); qual je meno modulu alebo None."""
    l = meno.lower()
    if qual is not None:
        m2 = svet.moduly.get(qual.lower())
        if m2 is None:
            return None, None
        return m2, m2.procs.get(l)
    if l in lokal or l in mod.premenne:
        return None, None
    if l in mod.procs:
        return mod, mod.procs[l]
    for m2, o in svet.verejne.get(l, []):
        if hasattr(o, "druh"):
            return m2, o
    return None, None


def typ_argumentu(arg, lokal, mod, svet):
    """Deklarovaný typ jednoduchého argumentu (identifikátor) alebo None."""
    a = arg.strip()
    if not re.match(r"^[A-Za-z_]\w*$", a):
        return None, None
    l = a.lower()
    v = lokal.get(l) or mod.premenne.get(l)
    if v is None:
        for m2, o in svet.verejne.get(l, []):
            if isinstance(o, dict):
                v = o
                break
    if v is None or v.get("konst"):
        return None, None
    return v["typ"], v["array"]


def kontrola_volani(svet, mod, proc, lokal, no, p, chyby, varovania):
    nazov_l = proc.nazov.lower()
    # 1) qualified: modul.Meno(  alebo  modul.Meno args (príkaz)
    for m in re.finditer(r"(?<![\w.!])([A-Za-z_]\w*)\s*\.\s*([A-Za-z_]\w*)", p):
        q, nm = m.group(1), m.group(2)
        if q.lower() not in svet.moduly or q.lower() in lokal:
            continue
        m2 = svet.moduly[q.lower()]
        o = m2.procs.get(nm.lower()) or m2.premenne.get(nm.lower())
        if o is None and nm.lower() in m2.enum:
            continue
        if o is None:
            chyby.append(Chyba("CHYBA", mod.nazov, no, "%s.%s: modul %s taký člen nemá (v %s)" % (q, nm, m2.nazov, proc.nazov)))
            continue
        verejny = o.verejna if hasattr(o, "verejna") else o.get("verejna")
        if not verejny:
            chyby.append(Chyba("CHYBA", mod.nazov, no, "%s.%s: člen je v module %s súkromný (v %s)" % (q, nm, m2.nazov, proc.nazov)))
            continue
        if hasattr(o, "druh"):
            args = argumenty_za(p, m.end())
            skontroluj_argumenty(svet, mod, proc, lokal, no, m2, o, args, chyby)
    # 2) bez kvalifikácie: Meno( ... ) alebo príkaz 'Meno arg, arg'
    for m in re.finditer(r"(?<![\w.!])([A-Za-z_]\w*)\s*\(", p):
        nm = m.group(1)
        l = nm.lower()
        if l == nazov_l or je_vstavane(nm) and l not in mod.procs:
            continue
        m2, o = najdi_cielovu_proceduru(svet, mod, None, nm, lokal)
        if o is None or not hasattr(o, "druh"):
            continue
        args = argumenty_za(p, m.end() - 1)
        skontroluj_argumenty(svet, mod, proc, lokal, no, m2, o, args, chyby)
    m = re.match(r"^(?:Call\s+)?([A-Za-z_]\w*)\b(?!\s*[=(.!:])\s*(.*)$", p, re.I)
    if m and not re.match(r"^(Call\s+)?[A-Za-z_]\w*\s*\(", p, re.I):
        nm = m.group(1)
        l = nm.lower()
        if not je_vstavane(nm) or l in mod.procs:
            m2, o = najdi_cielovu_proceduru(svet, mod, None, nm, lokal)
            if o is not None and getattr(o, "druh", "") == "sub" and l != nazov_l:
                rest = m.group(2).strip()
                args = deli_ciarky(rest) if rest else []
                skontroluj_argumenty(svet, mod, proc, lokal, no, m2, o, args, chyby)


def argumenty_za(p, pos):
    """Argumenty za zátvorkou na pozícii pos (p[pos] je '(') alebo za 'modul.Meno' (bez zátvorky = argumenty príkazu)."""
    i = pos
    while i < len(p) and p[i] == " ":
        i += 1
    if i < len(p) and p[i] == "(":
        k = parna_zatvorka(p, i)
        if k < 0:
            return []
        vnut = p[i + 1:k].strip()
        return deli_ciarky(vnut) if vnut else []
    rest = p[pos:].strip()
    if not rest or rest.startswith(("=", ".", ")")):
        return []
    # príkaz bez zátvoriek: 'modul.Sub a, b'
    return deli_ciarky(rest)


def skontroluj_argumenty(svet, mod, proc, lokal, no, cielmod, cproc, args, chyby):
    if cproc.druh == "declare":
        return
    if any(":=" in a for a in args):
        return
    n = len(args)
    pr = cproc.params
    ma_pa = any(x["paramarray"] for x in pr)
    pov = sum(1 for x in pr if not x["optional"] and not x["paramarray"])
    mx = 10 ** 6 if ma_pa else len(pr)
    if n < pov or n > mx:
        chyby.append(Chyba("CHYBA", mod.nazov, no, "%s.%s: %d argumentov, očakáva sa %s (v %s)" % (cielmod.nazov, cproc.nazov, n, ("%d" % pov) if pov == mx else "%d až %s" % (pov, "viac" if ma_pa else mx), proc.nazov)))
        return
    for a, prm in zip(args, pr):
        if prm["byval"] or prm["paramarray"]:
            continue
        if not a.strip():
            continue
        t, arr = typ_argumentu(a, lokal, mod, svet)
        if t is None:
            continue
        if prm["typ"] == "variant" and not prm["array"]:
            continue
        if t == prm["typ"] and bool(arr) == bool(prm["array"]):
            continue
        chyby.append(Chyba("CHYBA", mod.nazov, no, "ByRef argument '%s' (%s%s) nezodpovedá parametru %s.%s (%s%s) (v %s)" % (
            a.strip(), t, "()" if arr else "", cproc.nazov, prm["name"], prm["typ"], "()" if prm["array"] else "", proc.nazov)))


# ------------------------------------------------------------------ hlavná kontrola
def skontroluj(adresar):
    moduly = []
    for f in sorted(os.listdir(adresar)):
        if f.lower().endswith(".bas"):
            moduly.append(nacitaj_modul(os.path.join(adresar, f)))
    svet = Svet(moduly)
    varovania = []
    for m in moduly:
        if not m.option_explicit:
            m.chyby.append(Chyba("CHYBA", m.nazov, 1, "chýba Option Explicit"))
        for proc in m.vsetky_procs:
            kontrola_blokov(m, proc)
            kontrola_procedury(svet, m, proc, varovania, None)
    chyby = [c for m in moduly for c in m.chyby]
    return chyby, varovania


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--adresar", default=os.path.join(KOREN, "access", "moduly"))
    ap.add_argument("--varovania", action="store_true")
    a = ap.parse_args(argv)
    chyby, varovania = skontroluj(a.adresar)
    # duplicity (kontrola procedúry volá kontrola_volani pre každý príkaz; rovnaká chyba môže vyjsť dvakrát)
    videne, jedinecne = set(), []
    for c in chyby:
        k = (c.modul, c.riadok, c.text)
        if k not in videne:
            videne.add(k)
            jedinecne.append(c)
    for c in jedinecne:
        print(c)
    if a.varovania:
        for c in varovania:
            print(c)
    print("%d chýb%s" % (len(jedinecne), (", %d varovaní" % len(varovania)) if a.varovania else ""))
    return 1 if jedinecne else 0


if __name__ == "__main__":
    sys.exit(main())

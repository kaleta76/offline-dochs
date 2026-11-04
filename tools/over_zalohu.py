#!/usr/bin/env python3
"""Overenie a uloženie zálohy databázy stiahnutej z Lovable (docs/ZALOHA-DATABAZY.md). Len štandardná knižnica.

Lovable Cloud nedáva priamy prístup k databáze (ani adresu, ani kľúč), preto sa záloha nesťahuje skriptom, ale tlačidlom
Export v Lovable. Tento skript robí to, čo sa dá urobiť s hotovým súborom: overí, že je celý a obsahuje tabuľky tejto aplikácie,
spočíta kontrolný súčet SHA-256 a uloží kópiu do priečinka zalohy/RRRR-MM-DD_HHMM/ (zálohy do Gitu nepatria, sú v .gitignore).

Použitie (z koreňa repozitára; na Windowse `py -3 -I tools\\over_zalohu.py ...`):
    python3 -I tools/over_zalohu.py SUBOR                  # over a ulož kópiu do zalohy/
    python3 -I tools/over_zalohu.py SUBOR --iba-over       # len over, nič neukladá
    python3 -I tools/over_zalohu.py SUBOR --ulozit CESTA   # ulož inam než do zalohy/
    python3 -I tools/over_zalohu.py SUBOR --sha256 HEX     # porovná aj s kontrolným súčtom, ktorý poznáte
Kód ukončenia: 0 = v poriadku (aj s upozorneniami), 1 = problém (súbor nepoužívať).

Rozpozná formáty: pg_dump custom (PGDMP), tar, gzip, zip s jedným súborom a čistý SQL text. Export z Lovable je zip so súborom
*.backup, čo je archív pg_dump (custom), vytvorený novším PostgreSQL (17/18) a stlačený zstd. Takýto archív skript prečíta sám
(hlavička, zoznam tabuliek, celistvosť blokov údajov, prázdne tabuľky, pri gzip a bez kompresie aj počty riadkov), takže nepotrebuje
PostgreSQL. Ak je pg_restore nainštalovaný, použije sa ako doplnková kontrola. Pri SQL texte hľadá príkazy COPY.
Súbor nemení a nikam ho neposiela.
"""
import argparse, datetime, gzip, hashlib, io, json, os, re, shutil, subprocess, sys, tarfile, tempfile, zipfile, zlib

VERZIA_NASTROJA = "1.1"
# Tabuľky aplikácie, ktoré musí záloha obsahovať (údaje, nie len štruktúra). auth.users sú prihlasovacie účty.
OCAKAVANE = (
    "public.organizations", "public.profiles", "public.user_roles", "public.punches", "public.devices", "public.audit_log",
    "public.organization_settings", "public.organization_codes", "public.organization_holidays", "public.organization_invites",
    "public.corrections", "public.month_closures", "public.punch_void_requests", "public.personnel_requests",
    "public.notification_preferences", "auth.users",
)
# Tabuľky, ktoré v používanej aplikácii nie sú prázdne (organizácia, účty, role). Prázdna tu znamená chybný export.
POVINNE_NEPRAZDNE = ("public.organizations", "public.profiles", "public.user_roles", "auth.users")
MIN_BAJTOV = 1024
# pg_dump (custom) verzie archívu: 1.14 = PostgreSQL 12 až 15, 1.15 = 16, 1.16 = 17 a 18. Staršie a novšie nechá na pg_restore.
CUSTOM_MIN, CUSTOM_MAX = (1, 14), (1, 16)
KOMPRESIA = {0: "žiadna", 1: "gzip", 2: "lz4", 3: "zstd"}
KONIEC_COPY = b"\\.\n\n\n"  # pg_dump ním ukončí údaje každej tabuľky; prázdna tabuľka má obsah iba toto
MAX_RETAZEC = 1 << 24
MAX_POLOZIEK = 1_000_000
RE_TOC = re.compile(r"\bTABLE DATA\s+(\S+)\s+(\S+)\s")
RE_COPY = re.compile(r'^COPY\s+"?([A-Za-z0-9_]+)"?\."?([A-Za-z0-9_]+)"?[\s(]')
RE_INSERT = re.compile(r'^INSERT INTO\s+"?([A-Za-z0-9_]+)"?\."?([A-Za-z0-9_]+)"?[\s(]')


def sha256_suboru(cesta):
    h = hashlib.sha256()
    with open(cesta, "rb") as f:
        for blok in iter(lambda: f.read(1 << 20), b""):
            h.update(blok)
    return h.hexdigest()


def typ_z_hlavicky(hlavicka):
    """Rozpozná vrstvu podľa prvých bajtov (aspoň 512, ak súbor toľko má)."""
    if hlavicka.startswith(b"PGDMP"):
        return "pg_custom"
    if hlavicka.startswith(b"\x1f\x8b"):
        return "gzip"
    if hlavicka.startswith(b"PK\x03\x04"):
        return "zip"
    if len(hlavicka) >= 262 and hlavicka[257:262] == b"ustar":
        return "tar"
    if b"\x00" not in hlavicka:
        text = hlavicka.decode("utf-8", errors="ignore").lstrip("\ufeff")
        if re.search(r"^(--|SET |COPY |CREATE |INSERT |BEGIN)", text, re.M):
            return "sql"
    return "neznamy"


def tabulky_z_toc(vypis):
    """Zoznam tabuliek, ktorých ÚDAJE archív obsahuje, z výpisu `pg_restore --list`."""
    return sorted({f"{m.group(1)}.{m.group(2)}" for m in RE_TOC.finditer(vypis)})


def najdi_pg_restore():
    cesta = shutil.which("pg_restore")
    if cesta:
        return cesta
    if os.name == "nt":
        import glob
        nalezy = sorted(glob.glob(r"C:\Program Files\PostgreSQL\*\bin\pg_restore.exe"))
        if nalezy:
            return nalezy[-1]
    return None


def pg_restore_list(cesta):
    """Výpis obsahu archívu alebo None, ak pg_restore nie je k dispozícii. Chyba archívu vyhodí ValueError."""
    nastroj = najdi_pg_restore()
    if nastroj is None:
        return None
    r = subprocess.run([nastroj, "--list", cesta], capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise ValueError("pg_restore archív nepreberie: " + (r.stderr.strip().splitlines() or ["neznáma chyba"])[-1])
    return r.stdout


class NepodporovanaVerzia(ValueError):
    """Archív pg_dump má verziu, ktorú tento skript nečíta sám (rozhodne pg_restore)."""


def zstd_prazdny(blok):
    """True, ak je blok zstd rámec, ktorého obsah je iba koncovka COPY (prázdna tabuľka). Rámec sa nerozbaľuje, číta sa len jeho stavba."""
    if len(blok) < 9 or blok[:4] != b"\x28\xb5\x2f\xfd":
        return False
    d = blok[4]
    jeden_segment = (d >> 5) & 1
    kontrolny_sucet = (d >> 2) & 1
    poz = 5 + (0 if jeden_segment else 1) + (0, 1, 2, 4)[d & 3] + (1 if jeden_segment else 0, 2, 4, 8)[d >> 6]
    if len(blok) < poz + 3:
        return False
    hl = int.from_bytes(blok[poz:poz + 3], "little")
    posledny, typ, velkost = hl & 1, (hl >> 1) & 3, hl >> 3
    obsah = blok[poz + 3:poz + 3 + velkost]
    return bool(posledny) and typ == 0 and obsah == KONIEC_COPY and len(blok) == poz + 3 + velkost + (4 if kontrolny_sucet else 0)


def precitaj_custom(cesta):
    """Prečíta archív pg_dump (custom) sám, bez pg_restore: hlavičku, zoznam tabuliek s údajmi a celistvosť každého bloku údajov.

    Vráti slovník: verzia, kompresia, databaza, server, pg_dump, vytvorene, tabulky ({"schema.tabulka": {"stlacene", "riadky", "prazdna"}}),
    upozornenia. Počet riadkov je známy pri kompresii gzip a bez nej; pri zstd sa zistí aspoň to, či je tabuľka prázdna (inak None).
    Nepodporovanú verziu archívu hlási ako NepodporovanaVerzia, poškodený alebo useknutý archív ako ValueError."""
    velkost = os.path.getsize(cesta)
    with open(cesta, "rb") as f:
        def cit(n):
            b = f.read(n)
            if len(b) != n:
                raise ValueError("Archív pg_dump je useknutý (súbor končí skôr, než má): sťahovanie sa asi neskončilo, stiahnite ho znova.")
            return b

        if cit(5) != b"PGDMP":
            raise ValueError("Súbor nie je archív pg_dump.")
        vmaj, vmin, vrev = cit(3)
        if not (CUSTOM_MIN <= (vmaj, vmin) <= CUSTOM_MAX):
            raise NepodporovanaVerzia(f"{vmaj}.{vmin}.{vrev}")
        isz, osz, fmt = cit(3)
        if not (1 <= isz <= 8 and 1 <= osz <= 8) or fmt != 1:
            raise ValueError("Hlavička archívu pg_dump nie je platná.")

        def cint():
            znamienko = cit(1)[0]
            v = int.from_bytes(cit(isz), "little")
            return -v if znamienko else v

        def cstr():
            dlzka = cint()
            if dlzka < 0:
                return None
            if dlzka > MAX_RETAZEC:
                raise ValueError("Archív pg_dump je poškodený (neprimerane dlhý reťazec v obsahu).")
            return cit(dlzka).decode("utf-8", "replace")

        if (vmaj, vmin) >= (1, 15):
            komp = cit(1)[0]
        else:
            komp = 0 if cint() == 0 else 1  # staršie verzie: úroveň zlib (0 = bez kompresie, -1 a 1 až 9 = gzip)
        sec, minuta, hodina, den, mesiac, rok, _ = (cint() for _ in range(7))
        databaza, server, nastroj = cstr(), cstr(), cstr()
        pocet = cint()
        if not 0 < pocet <= MAX_POLOZIEK:
            raise ValueError("Archív pg_dump je poškodený (neplatný počet položiek obsahu).")
        polozky = []
        for _ in range(pocet):
            dump_id = cint()
            cint()  # hadDumper
            cstr(); cstr()  # tableoid, oid
            tag, popis = cstr(), cstr()
            cint()  # section
            cstr(); cstr()  # definícia, drop
            copy = cstr()
            schema = cstr()
            cstr(); cstr()  # tablespace, tableam
            if (vmaj, vmin) >= (1, 16):
                cint()  # relkind
            cstr(); cstr()  # owner, withOids
            while cstr() is not None:
                pass  # závislosti
            priznak = cit(1)[0]
            posun = int.from_bytes(cit(osz), "little")
            if popis == "TABLE DATA" and tag:
                polozky.append((dump_id, (schema + "." if schema else "") + tag, copy or "", priznak, posun))

        tabulky, upoz, bez_polohy = {}, [], 0
        for dump_id, nazov, copy, priznak, posun in polozky:
            if priznak != 2:  # poloha údajov nie je zapísaná (archív vznikol zápisom do rúry)
                bez_polohy += 1
                tabulky[nazov] = {"stlacene": None, "riadky": None, "prazdna": None}
                continue
            if not 0 < posun < velkost:
                raise ValueError(f"Archív pg_dump je poškodený: údaje tabuľky {nazov} ležia mimo súboru.")
            f.seek(posun)
            if cit(1)[0] != 1 or cint() != dump_id:
                raise ValueError(f"Archív pg_dump je poškodený: blok údajov tabuľky {nazov} nemá platnú hlavičku.")
            copy_rezim = copy.lstrip().upper().startswith("COPY")
            pocitat = copy_rezim and komp in (0, 1)
            dek = zlib.decompressobj() if komp == 1 else None
            celkom = kusy = riadky = 0
            koniec, prvy = b"", None
            while True:
                c = cint()
                if c == 0:
                    break
                if c < 0 or f.tell() + c > velkost:
                    raise ValueError(f"Archív pg_dump je useknutý alebo poškodený v údajoch tabuľky {nazov}.")
                celkom += c
                kusy += 1
                if pocitat:
                    zostava = c
                    while zostava:
                        cast = cit(min(zostava, 1 << 20))
                        zostava -= len(cast)
                        try:
                            vystup = dek.decompress(cast) if dek else cast
                        except zlib.error as e:
                            raise ValueError(f"Údaje tabuľky {nazov} sú poškodené (gzip: {e}).")
                        riadky += vystup.count(b"\n")
                        koniec = (koniec + vystup)[-len(KONIEC_COPY):]
                elif kusy == 1 and c <= 64:
                    prvy = cit(c)
                else:
                    f.seek(c, 1)
            if pocitat:
                if dek:
                    try:
                        vystup = dek.flush()
                    except zlib.error as e:
                        raise ValueError(f"Údaje tabuľky {nazov} sú poškodené (gzip: {e}).")
                    riadky += vystup.count(b"\n")
                    koniec = (koniec + vystup)[-len(KONIEC_COPY):]
                    if not dek.eof:
                        raise ValueError(f"Údaje tabuľky {nazov} sú neúplné (gzip sa neskončil).")
                if koniec != KONIEC_COPY:
                    raise ValueError(f"Údaje tabuľky {nazov} nekončia správne: archív je poškodený alebo useknutý.")
                riadky = max(0, riadky - KONIEC_COPY.count(b"\n"))
                tabulky[nazov] = {"stlacene": celkom, "riadky": riadky, "prazdna": riadky == 0}
            elif komp == 3 and copy_rezim and kusy == 1 and prvy is not None and zstd_prazdny(prvy):
                tabulky[nazov] = {"stlacene": celkom, "riadky": 0, "prazdna": True}
            elif komp == 3 and copy_rezim:
                tabulky[nazov] = {"stlacene": celkom, "riadky": None, "prazdna": False}
            else:
                tabulky[nazov] = {"stlacene": celkom, "riadky": None, "prazdna": None}
        if bez_polohy:
            upoz.append(f"Archív nemá zapísané polohy údajov ({bez_polohy} tabuliek; vznikol zápisom do rúry), preto sa celistvosť údajov a prázdne tabuľky nezisťovali.")
        if komp not in KOMPRESIA:
            upoz.append(f"Neznáma kompresia archívu ({komp}), celistvosť údajov sa nezisťovala.")
    try:
        vytvorene = f"{rok + 1900:04d}-{mesiac + 1:02d}-{den:02d} {hodina:02d}:{minuta:02d}:{sec:02d}"
    except (TypeError, ValueError):
        vytvorene = None
    return {
        "verzia": f"{vmaj}.{vmin}.{vrev}", "kompresia": KOMPRESIA.get(komp, f"neznáma ({komp})"), "databaza": databaza, "server": server,
        "pg_dump": nastroj, "vytvorene": vytvorene, "tabulky": tabulky, "upozornenia": upoz,
    }


def tabulky_zo_sql(prud):
    """Tabuľky, do ktorých textový SQL výpis vkladá údaje (COPY alebo INSERT). Číta po riadkoch, nič nenačítava celé."""
    najdene = set()
    for riadok in prud:
        if riadok[:4] in ("COPY", "INSE"):
            m = RE_COPY.match(riadok) or RE_INSERT.match(riadok)
            if m:
                najdene.add(f"{m.group(1)}.{m.group(2)}")
    return sorted(najdene)


def bezpecne_rozbal_tar(tf, cielovy):
    """Rozbalí len bežné súbory s bezpečným názvom (bez .., bez absolútnych ciest a odkazov)."""
    for clen in tf:
        nazov = clen.name.replace("\\", "/")
        if not clen.isfile() or nazov.startswith("/") or ".." in nazov.split("/") or re.match(r"^[A-Za-z]:", nazov):
            continue
        cesta = os.path.join(cielovy, *nazov.split("/"))
        os.makedirs(os.path.dirname(cesta), exist_ok=True)
        with tf.extractfile(clen) as src, open(cesta, "wb") as dst:
            shutil.copyfileobj(src, dst)


def preskumaj_custom(cesta):
    """Archív pg_dump (custom): vlastné čítanie, pg_restore len ako doplnok. Vráti (tabulky, upozornenia, podrobnosti) alebo None,
    ak je verzia archívu mimo toho, čo čítame sami (potom rozhodne pg_restore)."""
    try:
        info = precitaj_custom(cesta)
    except NepodporovanaVerzia:
        return None
    upoz = list(info["upozornenia"])
    tabulky = sorted(info["tabulky"])
    try:
        vypis = pg_restore_list(cesta)
    except ValueError as e:
        podrobnost = str(e).split(": ", 1)[-1]
        upoz.append(
            f"Nainštalovaný pg_restore tento archív neprečítal ({podrobnost}). Podľa vlastnej kontroly je archív v poriadku. Archív verzie "
            f"{info['verzia']} (server {info['server'] or '?'}, pg_dump {info['pg_dump'] or '?'}) obnovíte nástrojom pg_restore z PostgreSQL 17 alebo novšieho."
        )
    else:
        if vypis is not None and tabulky_z_toc(vypis) != tabulky:
            upoz.append("Zoznam tabuliek podľa pg_restore sa líši od vlastnej kontroly: archív si pred použitím overte v pg_restore --list.")
    return tabulky, upoz, info


def preskumaj(cesta, docasne, hlbka=0, podrobnosti=None):
    """Vráti (vrstvy, tabulky, upozornenia). Tabuľky je zoznam alebo None, ak sa obsah nedal overiť. Chybu vyhodí ako ValueError.
    Do slovníka `podrobnosti` (ak je zadaný) uloží pod kľúč "pg_custom" výsledok vlastného čítania archívu pg_dump."""
    if hlbka > 3:
        raise ValueError("Príliš veľa vnorených vrstiev (gzip/zip/tar).")
    with open(cesta, "rb") as f:
        hlavicka = f.read(512)
    typ = typ_z_hlavicky(hlavicka)
    upoz = []
    if typ == "neznamy":
        raise ValueError("Formát súboru sa nepodarilo rozpoznať (nie je to pg_dump, tar, gzip, zip ani SQL text).")
    if typ == "pg_custom":
        vlastne = preskumaj_custom(cesta)
        if vlastne is not None:
            tabulky, u, info = vlastne
            if podrobnosti is not None:
                podrobnosti["pg_custom"] = info
            return [typ], tabulky, upoz + u
        vypis = pg_restore_list(cesta)
        if vypis is None:
            return [typ], None, ["Nie je nainštalovaný pg_restore, obsah sa nedal overiť (súbor je však platná hlavička pg_dump)."]
        return [typ], tabulky_z_toc(vypis), upoz
    if typ == "sql":
        with open(cesta, "r", encoding="utf-8", errors="replace") as f:
            return [typ], tabulky_zo_sql(f), upoz
    if typ == "gzip":
        try:
            cesta2 = os.path.join(docasne, f"vrstva{hlbka}")
            with gzip.open(cesta, "rb") as g, open(cesta2, "wb") as out:
                shutil.copyfileobj(g, out, 1 << 20)
        except (EOFError, OSError) as e:
            raise ValueError(f"Súbor gzip je poškodený alebo neúplný ({e}).")
        try:
            vrstvy, tabulky, u = preskumaj(cesta2, docasne, hlbka + 1, podrobnosti)
        finally:
            os.remove(cesta2)
        return [typ] + vrstvy, tabulky, upoz + u
    if typ == "zip":
        try:
            with zipfile.ZipFile(cesta) as z:
                chyba = z.testzip()
                if chyba:
                    raise ValueError(f"Súbor zip je poškodený (člen {chyba}).")
                mena = [i for i in z.infolist() if not i.is_dir()]
                if len(mena) != 1:
                    return [typ], None, [f"Zip obsahuje {len(mena)} súborov; obsah sa neoveroval (rozbaľte ho a overte súbor so zálohou)."]
                cesta2 = os.path.join(docasne, f"vrstva{hlbka}")
                with z.open(mena[0]) as src, open(cesta2, "wb") as out:
                    shutil.copyfileobj(src, out, 1 << 20)
        except zipfile.BadZipFile as e:
            raise ValueError(f"Súbor zip je poškodený ({e}).")
        try:
            vrstvy, tabulky, u = preskumaj(cesta2, docasne, hlbka + 1, podrobnosti)
        finally:
            os.remove(cesta2)
        return [typ] + vrstvy, tabulky, upoz + u
    if typ == "tar":
        try:
            with tarfile.open(cesta) as tf:
                mena = [c.name for c in tf if c.isfile()]
                if "toc.dat" not in [m.split("/")[-1] for m in mena]:
                    return [typ], None, ["Tar neobsahuje toc.dat (nie je to archív pg_dump), obsah sa neoveroval."]
        except tarfile.TarError as e:
            raise ValueError(f"Súbor tar je poškodený ({e}).")
        # tar formát pg_dump (-Ft) pg_restore číta priamo, adresárový formát zbalený do tar treba najprv rozbaliť
        try:
            vypis = pg_restore_list(cesta)
        except ValueError:
            vypis = None
            tmp = tempfile.mkdtemp(prefix="zaloha_dir_")
            try:
                with tarfile.open(cesta) as tf:
                    bezpecne_rozbal_tar(tf, tmp)
                koren = tmp
                for kandidat, _, subory in os.walk(tmp):
                    if "toc.dat" in subory:
                        koren = kandidat
                        break
                vypis = pg_restore_list(koren)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        if vypis is None:
            return [typ], None, ["Nie je nainštalovaný pg_restore, obsah sa nedal overiť."]
        return [typ], tabulky_z_toc(vypis), upoz
    raise ValueError("Neočakávaný typ súboru.")


def over(cesta, ocakavany_sha=None):
    """Hlavná kontrola. Vráti slovník s kľúčmi problemy, upozornenia, sha256, bajty, vrstvy, tabulky, chybaju, archiv (podrobnosti pg_dump alebo None)."""
    v = {"subor": os.path.basename(cesta), "problemy": [], "upozornenia": [], "sha256": None, "bajty": 0, "vrstvy": [], "tabulky": None, "chybaju": [], "archiv": None}
    if not os.path.isfile(cesta):
        v["problemy"].append(f"Súbor neexistuje: {cesta}")
        return v
    v["bajty"] = os.path.getsize(cesta)
    if v["bajty"] < MIN_BAJTOV:
        v["problemy"].append(f"Súbor má len {v['bajty']} bajtov, záloha to nie je.")
        return v
    v["sha256"] = sha256_suboru(cesta)
    if ocakavany_sha and v["sha256"].lower() != ocakavany_sha.strip().lower():
        v["problemy"].append("Kontrolný súčet SHA-256 sa nezhoduje so zadaným: súbor sa pri sťahovaní poškodil alebo je to iný súbor.")
    tmp = tempfile.mkdtemp(prefix="zaloha_")
    podrobnosti = {}
    try:
        try:
            vrstvy, tabulky, upoz = preskumaj(cesta, tmp, 0, podrobnosti)
        except ValueError as e:
            v["problemy"].append(str(e))
            return v
        except subprocess.TimeoutExpired:
            v["problemy"].append("Kontrola obsahu trvala príliš dlho (pg_restore).")
            return v
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    v["vrstvy"], v["tabulky"] = vrstvy, tabulky
    v["upozornenia"].extend(upoz)
    if tabulky is not None:
        v["chybaju"] = [t for t in OCAKAVANE if t not in tabulky]
        if v["chybaju"]:
            v["problemy"].append("V zálohe chýbajú údaje tabuliek: " + ", ".join(v["chybaju"]) + ".")
    v["archiv"] = podrobnosti.get("pg_custom")
    if v["archiv"]:
        prazdne = [t for t in POVINNE_NEPRAZDNE if v["archiv"]["tabulky"].get(t, {}).get("prazdna") is True]
        if prazdne:
            v["problemy"].append("V zálohe sú prázdne tabuľky, ktoré v používanej aplikácii prázdne nebývajú: " + ", ".join(prazdne) + ".")
    return v


def ulozit(cesta, koren, v, teraz=None):
    """Uloží kópiu so súčtom a manifestom do KOREN/RRRR-MM-DD_HHMM/ (nikdy neprepíše existujúci priečinok). Vráti cestu priečinka."""
    teraz = teraz or datetime.datetime.now().astimezone()
    zaklad = os.path.join(koren, teraz.strftime("%Y-%m-%d_%H%M"))
    cielovy, n = zaklad, 1
    while os.path.exists(cielovy):
        n += 1
        cielovy = f"{zaklad}-{n}"
    os.makedirs(cielovy)
    nazov = os.path.basename(cesta)
    kopia = os.path.join(cielovy, nazov)
    shutil.copy2(cesta, kopia)
    if sha256_suboru(kopia) != v["sha256"]:
        shutil.rmtree(cielovy, ignore_errors=True)
        raise OSError("Kópia sa nezhoduje s originálom (chyba disku alebo prerušené kopírovanie).")
    with open(os.path.join(cielovy, nazov + ".sha256"), "w", encoding="utf-8") as f:
        f.write(f"{v['sha256']}  {nazov}\n")
    manifest = {
        "nastroj": f"over_zalohu.py {VERZIA_NASTROJA}", "vytvorene": teraz.isoformat(timespec="seconds"), "subor": nazov, "bajty": v["bajty"],
        "sha256": v["sha256"], "vrstvy": v["vrstvy"], "tabulky_s_udajmi": v["tabulky"], "upozornenia": v["upozornenia"],
    }
    if v.get("archiv"):
        a = v["archiv"]
        manifest["archiv"] = {k: a[k] for k in ("verzia", "kompresia", "databaza", "server", "pg_dump", "vytvorene")}
        manifest["archiv"]["ocakavane_tabulky"] = {t: a["tabulky"][t] for t in OCAKAVANE if t in a["tabulky"]}
    with open(os.path.join(cielovy, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    try:
        os.chmod(kopia, 0o444)
    except OSError:
        pass
    return cielovy


def mnozne(n, jedno, par, vela):
    return jedno if n == 1 else par if 2 <= n <= 4 else vela


def popis_tabulky(t):
    """Jednoriadkový popis obsahu tabuľky v zálohe pre výpis."""
    if t["riadky"] is not None and t["riadky"] > 0:
        return f"{t['riadky']} {mnozne(t['riadky'], 'riadok', 'riadky', 'riadkov')}"
    if t["prazdna"] is True:
        return "prázdna"
    if t["prazdna"] is False:
        return "obsahuje údaje (počet riadkov sa pri tejto kompresii nezisťuje)"
    return "údaje nie sú overené"


def hlavna(argv=None, vystup=None):
    vystup = vystup or sys.stdout
    p = argparse.ArgumentParser(description="Overí a uloží zálohu databázy stiahnutú z Lovable.")
    p.add_argument("subor", help="stiahnutý súbor so zálohou")
    p.add_argument("--iba-over", action="store_true", help="nič neukladať")
    p.add_argument("--ulozit", metavar="CESTA", default="zalohy", help="kam uložiť kópiu (predvolené: zalohy/)")
    p.add_argument("--sha256", metavar="HEX", help="kontrolný súčet, s ktorým sa má súbor zhodovať")
    a = p.parse_args(argv)

    def tlac(*t):
        print(*t, file=vystup)

    v = over(a.subor, a.sha256)
    tlac("Súbor:        " + v["subor"] + " (" + f"{v['bajty']:,}".replace(",", " ") + " bajtov)")
    if v["sha256"]:
        tlac(f"SHA-256:      {v['sha256']}")
    if v["vrstvy"]:
        tlac("Formát:       " + " → ".join(v["vrstvy"]))
    ar = v["archiv"]
    if ar:
        tlac(f"Archív pg_dump {ar['verzia']}: server PostgreSQL {ar['server'] or '?'}, pg_dump {ar['pg_dump'] or '?'}, kompresia {ar['kompresia']}, "
             f"vytvorený {ar['vytvorene'] or '?'} (čas na stroji, kde sa export robil)")
    if v["tabulky"] is not None:
        tlac(f"Tabuľky s údajmi: {len(v['tabulky'])}, z toho očakávaných {len(OCAKAVANE) - len(v['chybaju'])} z {len(OCAKAVANE)}")
    if ar:
        for t in OCAKAVANE:
            if t in ar["tabulky"]:
                tlac(f"  {t:<34} {popis_tabulky(ar['tabulky'][t])}")
    for u in v["upozornenia"]:
        tlac("UPOZORNENIE:", u)
    for x in v["problemy"]:
        tlac("PROBLÉM:", x)
    if v["problemy"]:
        tlac("\nTento súbor ako zálohu NEPOUŽÍVAJTE. Urobte Export v Lovable znova (docs/ZALOHA-DATABAZY.md).")
        return 1
    if a.iba_over:
        tlac("\nV poriadku (nič sa neukladalo).")
        return 0
    try:
        priecinok = ulozit(a.subor, a.ulozit, v)
    except OSError as e:
        tlac("PROBLÉM:", e)
        return 1
    tlac(f"\nV poriadku. Kópia je uložená v: {priecinok}")
    tlac("Súbor obsahuje prihlasovacie účty a odtlačky hesiel: uchovajte ho na šifrovanom disku a nikdy ho nenahrávajte na GitHub.")
    return 0


if __name__ == "__main__":
    sys.exit(hlavna())

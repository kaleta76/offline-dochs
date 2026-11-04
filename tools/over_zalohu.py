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

Rozpozná formáty: pg_dump custom (PGDMP), tar, gzip, zip s jedným súborom a čistý SQL text. Obsah (zoznam tabuliek) overí pomocou
pg_restore --list (ak je nainštalovaný, súčasť PostgreSQL), pri SQL texte hľadá príkazy COPY. Súbor nemení a nikam ho neposiela.
"""
import argparse, datetime, gzip, hashlib, io, json, os, re, shutil, subprocess, sys, tarfile, tempfile, zipfile

VERZIA_NASTROJA = "1.0"
# Tabuľky aplikácie, ktoré musí záloha obsahovať (údaje, nie len štruktúra). auth.users sú prihlasovacie účty.
OCAKAVANE = (
    "public.organizations", "public.profiles", "public.user_roles", "public.punches", "public.devices", "public.audit_log",
    "public.organization_settings", "public.organization_codes", "public.organization_holidays", "public.organization_invites",
    "public.corrections", "public.month_closures", "public.punch_void_requests", "public.personnel_requests",
    "public.notification_preferences", "auth.users",
)
MIN_BAJTOV = 1024
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


def preskumaj(cesta, docasne, hlbka=0):
    """Vráti (vrstvy, tabulky, upozornenia). Tabuľky je zoznam alebo None, ak sa obsah nedal overiť. Chybu vyhodí ako ValueError."""
    if hlbka > 3:
        raise ValueError("Príliš veľa vnorených vrstiev (gzip/zip/tar).")
    with open(cesta, "rb") as f:
        hlavicka = f.read(512)
    typ = typ_z_hlavicky(hlavicka)
    upoz = []
    if typ == "neznamy":
        raise ValueError("Formát súboru sa nepodarilo rozpoznať (nie je to pg_dump, tar, gzip, zip ani SQL text).")
    if typ == "pg_custom":
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
            vrstvy, tabulky, u = preskumaj(cesta2, docasne, hlbka + 1)
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
            vrstvy, tabulky, u = preskumaj(cesta2, docasne, hlbka + 1)
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
    """Hlavná kontrola. Vráti slovník s kľúčmi problemy, upozornenia, sha256, bajty, vrstvy, tabulky, chybaju."""
    v = {"subor": os.path.basename(cesta), "problemy": [], "upozornenia": [], "sha256": None, "bajty": 0, "vrstvy": [], "tabulky": None, "chybaju": []}
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
    try:
        try:
            vrstvy, tabulky, upoz = preskumaj(cesta, tmp)
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
    with open(os.path.join(cielovy, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    try:
        os.chmod(kopia, 0o444)
    except OSError:
        pass
    return cielovy


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
    if v["tabulky"] is not None:
        tlac(f"Tabuľky s údajmi: {len(v['tabulky'])}, z toho očakávaných {len(OCAKAVANE) - len(v['chybaju'])} z {len(OCAKAVANE)}")
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

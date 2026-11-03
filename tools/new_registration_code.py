#!/usr/bin/env python3
"""Vygeneruje nový registračný kód firmy a jeho odtlačok (SHA-256) pre src/lib/registration-code.ts.

Použitie:  python3 -I tools/new_registration_code.py            # nový kód
           python3 -I tools/new_registration_code.py "ABCD-EFGH-..."   # len odtlačok existujúceho kódu

Kód pošlite e-mailom firmám. Do repozitára patrí iba odtlačok, nikdy samotný kód.
Normalizácia musí byť rovnaká ako normalizeCode() v src/lib/credentials.ts.
"""
import hashlib
import re
import secrets
import sys

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"  # Crockford base32


def normalize(code: str) -> str:
    return re.sub(r"[IL]", "1", re.sub(r"O", "0", re.sub(r"[\s-]", "", code.upper())))


def main() -> None:
    if len(sys.argv) > 1:
        code = sys.argv[1]
    else:
        raw = "".join(ALPHABET[b % 32] for b in secrets.token_bytes(20))  # 100 bitov
        code = "-".join(raw[i : i + 4] for i in range(0, 20, 4))
        print("Registračný kód (pošlite firmám):", code)
    digest = hashlib.sha256(normalize(code).encode()).hexdigest()
    print("Odtlačok pre src/lib/registration-code.ts:", digest)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# Сборка zip модуля Magisk. Кроссплатформенно и детерминированно:
# нормализует переводы строк в LF и явно проставляет unix-режимы,
# поэтому итог не зависит от того, на Windows собирают или нет.
# Запуск: python build.py [--push]  (--push отправляет zip на устройство через adb)
import os, sys, time, stat, zipfile, subprocess, shutil

ROOT = os.path.dirname(os.path.abspath(__file__))

# Детерминированная временная метка (UTC): без неё байты zip зависят от часов и
# таймзоны сборки. SOURCE_DATE_EPOCH уважается CI; дефолт — 1980-01-01 (нижняя
# граница формата zip). localtime не годится — тогда «детерминированно» неправда.
_EPOCH = max(int(os.environ.get("SOURCE_DATE_EPOCH", "315532800")), 315532800)
MTIME = time.gmtime(_EPOCH)[:6]

# (путь в архиве, unix-режим). Порядок = порядок в zip.
FILES = [
    ("module.prop", 0o644),
    ("config", 0o644),
    ("customize.sh", 0o644),
    ("service.sh", 0o755),
    ("META-INF/com/google/android/update-binary", 0o755),
    ("META-INF/com/google/android/updater-script", 0o644),
]

# Текстовые файлы принудительно в LF; бинарных в модуле нет.
def read_lf(path):
    with open(path, "rb") as f:
        return f.read().replace(b"\r\n", b"\n").replace(b"\r", b"\n")

def version():
    for line in read_lf(os.path.join(ROOT, "module.prop")).decode().splitlines():
        if line.startswith("version="):
            return line.split("=", 1)[1].strip()
    sys.exit("[ERROR] version= not found in module.prop")

def main():
    ver = version()
    out = os.path.join(ROOT, f"magisk-wifiadb-{ver}.zip")
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel, mode in FILES:
            src = os.path.join(ROOT, rel.replace("/", os.sep))
            if not os.path.isfile(src):
                sys.exit(f"[ERROR] missing file: {rel}")
            zi = zipfile.ZipInfo(rel, date_time=MTIME)
            zi.create_system = 3  # Unix — иначе на Windows пишется FAT (0) и распаковщик игнорирует режимы
            zi.external_attr = (stat.S_IFREG | (mode & 0o7777)) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, read_lf(src))

    # Верификация: точный состав, Unix-origin, ни одного CRLF, верные режимы.
    bad = []
    with zipfile.ZipFile(out) as z:
        want = dict(FILES)
        names = z.namelist()
        if names != [rel for rel, _ in FILES]:
            bad.append(f"entry list mismatch: {names}")
        for zi in z.infolist():
            data = z.read(zi.filename)
            mode = (zi.external_attr >> 16) & 0o777
            if zi.create_system != 3:
                bad.append(f"non-Unix entry (create_system={zi.create_system}) for {zi.filename}")
            if b"\r\n" in data:
                bad.append(f"CRLF in {zi.filename}")
            if mode != want.get(zi.filename):
                bad.append(f"mode {oct(mode)} != {oct(want.get(zi.filename))} for {zi.filename}")
    if bad:
        sys.exit("[ERROR] verification failed:\n  " + "\n  ".join(bad))

    print(f"Built: {os.path.basename(out)}  (LF + exec bits verified)")
    return out

def push(out):
    adb = shutil.which("adb")
    if not adb:
        return
    devs = subprocess.run([adb, "devices"], capture_output=True, text=True).stdout
    if not any(l.strip().endswith("\tdevice") for l in devs.splitlines()):
        return
    subprocess.run([adb, "push", out, "/data/local/tmp/"])
    name = os.path.basename(out)
    print("\nTo install via Magisk:")
    print(f'  adb shell su -c "magisk --install-module /data/local/tmp/{name}"')
    print("Or flash manually via Magisk Manager.")

if __name__ == "__main__":
    out = main()
    if "--push" in sys.argv[1:]:
        push(out)

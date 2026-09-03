"""Check archived binaries against their sha256 manifest.

The binaries under baseline/ are deliberately not committed - they are the
game's own executable and a third-party DLL, neither of which is ours to
redistribute. Only the manifest is. So on any machine other than the one that
made the archive, the files have to be brought in by hand, and this says
whether what arrived is what the manifest describes.

A mismatch on the server executable means the game updated. The archive is
then stale, and any hardcoded offsets validated against it (the Stage 3
ProcessEvent RVA in particular) must not be trusted.

Usage:
    python tools/verify_baseline.py                 # every manifest under baseline/
    python tools/verify_baseline.py <manifest ...>  # specific ones

Exit status is 0 only if every listed file is present and matches.
"""
import glob, hashlib, os, sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(KIT, "baseline")


def read_manifest(path):
    """-> [(sha256 lowercase, filename)].

    Accepts the `HASH *NAME` form sha256sum writes in binary mode, and tolerates
    CRLF: the manifests here are CRLF, which makes `sha256sum -c` fail on the
    filename with a stray carriage return."""
    out = []
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            digest, sep, name = line.partition(" *")
            if not sep:
                digest, sep, name = line.partition("  ")
            if not sep:
                print(f"  ! unparseable line in {os.path.basename(path)}: {line!r}")
                return None
            out.append((digest.strip().lower(), name.strip()))
    return out


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        # The archived executable is ~90 MB; read it in chunks rather than
        # holding the whole thing in memory.
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(manifest):
    rel = os.path.relpath(manifest, KIT)
    entries = read_manifest(manifest)
    if entries is None:
        return False
    print(f"\n  {rel}")
    ok = True
    for want, name in entries:
        path = os.path.join(os.path.dirname(manifest), name)
        if not os.path.isfile(path):
            print(f"    MISSING   {name}")
            print(f"              copy it in, or restore the game files via "
                  f"Steam > verify integrity")
            ok = False
            continue
        got = sha256(path)
        if got == want:
            print(f"    ok        {name}")
        else:
            print(f"    MISMATCH  {name}")
            print(f"              expected {want}")
            print(f"              found    {got}")
            ok = False
    return ok


def main(argv):
    manifests = argv or sorted(
        glob.glob(os.path.join(BASELINE, "**", "manifest.sha256"), recursive=True))
    if not manifests:
        print("  no manifest found under baseline/")
        return 1
    results = [verify(m) for m in manifests]
    print()
    if all(results):
        print(f"  {len(manifests)} manifest(s) verified.\n")
        return 0
    print(f"  {results.count(False)} of {len(manifests)} manifest(s) FAILED.\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

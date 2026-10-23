#!/usr/bin/env python3
"""Upload the store listings in fastlane/metadata/android/ to Google Play.

Every <locale>/ folder with title.txt, short_description.txt and
full_description.txt becomes that language's listing: added if Play
doesn't have it yet, otherwise its three texts are replaced. The default
language's listing (en-US) is left alone unless --include-default is
given. Screenshots, icons, videos and changelogs aren't touched.

Needs a Google Cloud service account with a JSON key, invited in Play
Console (Users and permissions) with access to the app's store listing,
and `openssl` on the PATH. No Python packages.

    python3 fastlane/upload_listings.py KEY.json [--locales de-DE,ru-RU]
        [--include-default] [--send-for-review]
    python3 fastlane/upload_listings.py --dry-run

The changes are saved without being sent for review: Publishing overview
in Play Console lists them, ready to send together with a release.
--send-for-review sends them straight away.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
METADATA = HERE / "metadata" / "android"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"

# Play's limits, in characters.
FIELDS = {
    "title": ("title.txt", 30),
    "shortDescription": ("short_description.txt", 80),
    "fullDescription": ("full_description.txt", 4000),
}


def read_listings() -> dict[str, dict[str, str]]:
    listings = {}
    for d in sorted(p for p in METADATA.iterdir() if p.is_dir()):
        if all((d / name).is_file() for name, _ in FIELDS.values()):
            listings[d.name] = {
                key: (d / name).read_text(encoding="utf-8").strip()
                for key, (name, _) in FIELDS.items()
            }
    return listings


def too_long(listings) -> list[str]:
    return [
        f"{loc}: {FIELDS[key][0]} has {len(text)} characters, "
        f"the limit is {FIELDS[key][1]}"
        for loc, texts in listings.items()
        for key, text in texts.items()
        if len(text) > FIELDS[key][1]
    ]


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def sign_rs256(data: bytes, pem: str) -> bytes:
    # The key goes to openssl through a pipe, never through a file.
    r, w = os.pipe()
    os.write(w, pem.encode())
    os.close(w)
    try:
        return subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", f"/dev/fd/{r}"],
            input=data, capture_output=True, check=True, pass_fds=(r,),
        ).stdout
    finally:
        os.close(r)


def access_token(key: dict) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = b64url(json.dumps({
        "iss": key["client_email"],
        "scope": SCOPE,
        "aud": key["token_uri"],
        "iat": now,
        "exp": now + 3600,
    }).encode())
    unsigned = f"{header}.{claims}".encode()
    jwt = f"{header}.{claims}.{b64url(sign_rs256(unsigned, key['private_key']))}"
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt,
    }).encode()
    with urllib.request.urlopen(key["token_uri"], body) as resp:
        return json.load(resp)["access_token"]


class Play:
    def __init__(self, token: str, package: str):
        self.token = token
        self.base = f"{API}/{package}"

    def call(self, method: str, path: str, body=None):
        req = urllib.request.Request(
            self.base + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
        return json.loads(raw) if raw else {}


def api_error(e: urllib.error.HTTPError) -> str:
    try:
        return json.load(e)["error"]["message"]
    except Exception:
        return f"HTTP {e.code}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("key", nargs="?", help="service account JSON key")
    ap.add_argument("--locales", help="comma-separated, e.g. de-DE,ru-RU")
    ap.add_argument("--include-default", action="store_true",
                    help="also replace the default language's listing")
    ap.add_argument("--send-for-review", action="store_true")
    ap.add_argument("--dry-run", action="store_true",
                    help="only check the texts, no upload")
    ap.add_argument("--package", help="default: from fastlane/Appfile")
    args = ap.parse_args()

    listings = read_listings()
    if args.locales:
        wanted = args.locales.split(",")
        missing = [loc for loc in wanted if loc not in listings]
        if missing:
            sys.exit(f"No listing folder for: {', '.join(missing)}")
        listings = {loc: listings[loc] for loc in wanted}
    errors = too_long(listings)
    if errors:
        sys.exit("\n".join(errors))

    if args.dry_run:
        for loc, texts in listings.items():
            sizes = ", ".join(
                f"{FIELDS[k][0].removesuffix('.txt')} {len(t)}/{FIELDS[k][1]}"
                for k, t in texts.items())
            print(f"{loc:8} {texts['title']!r:36} {sizes}")
        return
    if not args.key:
        ap.error("the service account key is needed (or use --dry-run)")

    package = args.package
    if not package:
        m = re.search(r'package_name\("([^"]+)"\)',
                      (HERE / "Appfile").read_text())
        package = m.group(1)

    key = json.loads(Path(args.key).read_text())
    try:
        play = Play(access_token(key), package)
        edit = play.call("POST", "/edits", {})["id"]
    except urllib.error.HTTPError as e:
        sys.exit(f"Couldn't open an edit for {package}: {api_error(e)}")

    try:
        default = play.call("GET", f"/edits/{edit}/details")["defaultLanguage"]
        existing = {
            item["language"]
            for item in play.call("GET", f"/edits/{edit}/listings")
            .get("listings", [])
        }
        for loc, texts in listings.items():
            if loc == default and not args.include_default:
                print(f"{loc:8} skipped (default language)")
                continue
            path = f"/edits/{edit}/listings/{loc}"
            if loc in existing:
                # PATCH keeps the listing's other fields, such as the video.
                play.call("PATCH", path, texts)
                print(f"{loc:8} updated")
            else:
                play.call("PUT", path, {"language": loc, **texts})
                print(f"{loc:8} added")
        query = "" if args.send_for_review else "?changesNotSentForReview=true"
        play.call("POST", f"/edits/{edit}:commit{query}")
    except urllib.error.HTTPError as e:
        try:
            play.call("DELETE", f"/edits/{edit}")
        except urllib.error.HTTPError:
            pass
        sys.exit(f"Nothing was changed: {api_error(e)}")

    if args.send_for_review:
        print("Saved and sent for review.")
    else:
        print("Saved. Send the changes for review in Play Console >"
              " Publishing overview.")


if __name__ == "__main__":
    main()

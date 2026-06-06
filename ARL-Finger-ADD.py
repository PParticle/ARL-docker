#!/usr/bin/env python3
# -*- coding:utf-8 -*-

import json
import sys
import time
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

requests.packages.urllib3.disable_warnings()

DEFAULT_TIMEOUT = 15
PROGRESS_EVERY = 200
FINGERPRINT_FILE = Path("./finger.json")


def normalize_base_url(url):
    return url.rstrip("/") + "/"


def build_session():
    session = requests.Session()
    session.verify = False
    session.trust_env = False
    session.headers.update(
        {
            "Accept": "application/json, text/plain, */*",
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/74.0.3729.131 Safari/537.36"
            ),
            "Connection": "keep-alive",
            "Accept-Encoding": "gzip, deflate",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Content-Type": "application/json; charset=UTF-8",
        }
    )

    retry = Retry(
        total=3,
        connect=3,
        read=3,
        backoff_factor=0.5,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=frozenset(["GET", "POST"]),
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry, pool_connections=20, pool_maxsize=20)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session


def login(session, base_url, username, password):
    response = session.post(
        f"{base_url}api/user/login",
        json={"username": username, "password": password},
        timeout=DEFAULT_TIMEOUT,
    )
    response.raise_for_status()
    payload = response.json()
    token = payload.get("data", {}).get("token")
    if not token:
        raise RuntimeError(f"login failed: {response.text}")
    session.headers["Token"] = token
    return token


def load_fingerprints():
    with FINGERPRINT_FILE.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return payload.get("fingerprint", [])


def build_rule(fingerprint):
    keywords = fingerprint.get("keyword") or []
    if not keywords:
        return None

    keyword = keywords[0]
    if fingerprint.get("method") == "keyword" and fingerprint.get("location") == "body":
        return f'body="{keyword}"'
    if fingerprint.get("method") == "keyword" and fingerprint.get("location") == "title":
        return f'title="{keyword}"'
    return f'icon_hash="{keyword}"'


def iter_import_items(fingerprints):
    for fingerprint in fingerprints:
        name = fingerprint.get("cms")
        rule = build_rule(fingerprint)
        if not name or not rule:
            continue
        yield {"name": name, "human_rule": rule}


def import_fingerprints(session, base_url):
    raw_fingerprints = load_fingerprints()
    items = list(iter_import_items(raw_fingerprints))
    total = len(items)
    target_url = f"{base_url}api/fingerprint/"
    success = 0
    failed = 0
    started_at = time.time()

    print(f"[+] Login Success!!")
    print(f"[+] Start importing fingerprints: total={total}")

    for index, item in enumerate(items, start=1):
        try:
            response = session.post(target_url, json=item, timeout=DEFAULT_TIMEOUT)
            if response.status_code == 200:
                success += 1
            else:
                failed += 1
                print(
                    f"[-] #{index} {item['name']}: status={response.status_code} "
                    f"body={response.text[:200]}"
                )
        except requests.RequestException as exc:
            failed += 1
            print(f"[-] #{index} {item['name']}: {exc}")

        if index % PROGRESS_EVERY == 0 or index == total:
            elapsed = time.time() - started_at
            print(
                f"[.] Progress {index}/{total} "
                f"success={success} failed={failed} elapsed={elapsed:.1f}s"
            )

    elapsed = time.time() - started_at
    print(
        f"[+] Import finished: total={total} success={success} "
        f"failed={failed} elapsed={elapsed:.1f}s"
    )


def main():
    if len(sys.argv) != 4:
        print(
            """
    usage:

        python3 ARL-Finger-ADD.py https://192.168.1.1:5003/ admin password

                                                         by loecho
            """.rstrip()
        )
        return 1

    base_url = normalize_base_url(sys.argv[1])
    username = sys.argv[2]
    password = sys.argv[3]

    session = build_session()
    login(session, base_url, username, password)
    import_fingerprints(session, base_url)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(exc)
        raise

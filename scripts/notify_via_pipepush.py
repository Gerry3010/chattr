#!/usr/bin/env python3
"""Fasst die Security-Scan-Ergebnisse zusammen und schickt EINE pipepush-
Benachrichtigung über das reale Webhook-Contract.

Gedacht als letzter Step der Bitbucket-Pipeline `weekly-full-security-scan`.
Liest die von den Scan-Steps abgelegten Report-Dateien (Semgrep/Trivy/ZAP als
JSON, govulncheck als Text), baut eine kompakte Zusammenfassung inkl. eines
Log-Ausschnitts und POSTet sie an pipepush.

Contract (siehe bitbucket-pipelines.yml Deploy-Step + CLAUDE.md):
    POST $PIPEPUSH_SERVER/api/webhook
    { token, status, pipeline, branch, commit, runId, message }

`status` = "failure", sobald es HIGH/CRITICAL-Findings gibt, sonst "success".
Bewusst KEIN Abruf von "pipepush-eigenen Logs" — pipepush ist ein reiner
Webhook-Empfänger ohne Log-Endpoint. Der Log-Ausschnitt sind die Scan-Logs
selbst (Findings-Auszug), verpackt ins `message`-Feld.

Es landen nur Zähler + Regel-IDs/Pfade in der message — keine Secrets, keine
Nutzerdaten.
"""

from __future__ import annotations

import json
import os
import sys

try:
    import requests
except ImportError:  # das Image installiert requests; lokal ggf. nicht
    requests = None

MESSAGE_CHAR_LIMIT = 3500  # pipepush-Notification kurz halten

# --- Report-Dateien (von den Scan-Steps als Artefakte abgelegt) --------------
SEMGREP_JSON = "semgrep-results.json"
TRIVY_JSON = "trivy-fs-results.json"
GOVULN_TXT = "govulncheck-results.txt"
ZAP_JSON = "zap-report.json"


def _load_json(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as exc:  # kaputtes/leeres JSON darf nicht crashen
        print(f"warn: konnte {path} nicht parsen: {exc}", file=sys.stderr)
        return None


def summarize_semgrep():
    """→ (line, high_count). Semgrep-Severity: ERROR/WARNING/INFO."""
    data = _load_json(SEMGREP_JSON)
    if data is None:
        return "Semgrep (SAST): keine Ergebnisdatei", 0
    results = data.get("results", []) if isinstance(data, dict) else []
    sev = {"ERROR": 0, "WARNING": 0, "INFO": 0}
    for r in results:
        s = (r.get("extra", {}) or {}).get("severity", "INFO")
        sev[s] = sev.get(s, 0) + 1
    total = len(results)
    line = (
        f"Semgrep (SAST): {total} Findings "
        f"(error:{sev['ERROR']} warn:{sev['WARNING']} info:{sev['INFO']})"
    )
    return line, sev["ERROR"]  # ERROR ~ HIGH


def summarize_trivy():
    """→ (line, high_count). Wir scannen nur HIGH,CRITICAL."""
    data = _load_json(TRIVY_JSON)
    if data is None:
        return "Trivy (Deps): keine Ergebnisdatei", 0
    results = data.get("Results", []) if isinstance(data, dict) else []
    sev = {"CRITICAL": 0, "HIGH": 0}
    for res in results:
        for v in res.get("Vulnerabilities", []) or []:
            s = v.get("Severity", "")
            if s in sev:
                sev[s] += 1
    total = sev["CRITICAL"] + sev["HIGH"]
    line = f"Trivy (Deps): {total} HIGH/CRIT (crit:{sev['CRITICAL']} high:{sev['HIGH']})"
    return line, total


def summarize_govulncheck():
    """→ (line, count). Text-Report; zähle 'Vulnerability #'-Header."""
    if not os.path.exists(GOVULN_TXT):
        return "govulncheck (Go): keine Ergebnisdatei", 0
    try:
        with open(GOVULN_TXT, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except Exception:
        return "govulncheck (Go): Report unlesbar", 0
    count = text.count("Vulnerability #")
    if count == 0 and "No vulnerabilities found" in text:
        return "govulncheck (Go): keine bekannten CVEs", 0
    return f"govulncheck (Go): {count} Vulnerabilities", count


def summarize_zap():
    """→ (line, high_count). ZAP riskcode: 3=High,2=Med,1=Low,0=Info."""
    data = _load_json(ZAP_JSON)
    if data is None:
        return "ZAP (DAST): nicht gelaufen (kein STAGING_URL / kein Report)", 0
    sites = data.get("site", []) if isinstance(data, dict) else []
    risk = {"3": 0, "2": 0, "1": 0, "0": 0}
    for site in sites:
        for alert in site.get("alerts", []) or []:
            rc = str(alert.get("riskcode", "0"))
            risk[rc] = risk.get(rc, 0) + 1
    line = (
        f"ZAP (DAST): high:{risk['3']} med:{risk['2']} "
        f"low:{risk['1']} info:{risk['0']}"
    )
    return line, risk["3"]


def build_log_url():
    """Klickbarer Link zur Pipeline-Ausführung (aus den BB-Vars), sonst None."""
    ws = os.environ.get("BITBUCKET_WORKSPACE")
    repo = os.environ.get("BITBUCKET_REPO_SLUG")
    build = os.environ.get("BITBUCKET_BUILD_NUMBER")
    if ws and repo and build:
        return f"https://bitbucket.org/{ws}/{repo}/pipelines/results/{build}"
    return None


def build_message(lines, high_total):
    header = "🔒 Wöchentlicher Security-Scan — chattr"
    verdict = (
        f"⚠️ {high_total} HIGH/CRITICAL-Finding(s)"
        if high_total > 0
        else "✅ keine HIGH/CRITICAL-Findings"
    )
    body = "\n".join([header, verdict, "—", *lines])
    if len(body) > MESSAGE_CHAR_LIMIT:
        body = body[: MESSAGE_CHAR_LIMIT - 1] + "…"
    # Log-Link ans Ende (nach dem Deckeln, damit er nie abgeschnitten wird).
    log_url = build_log_url()
    if log_url:
        body = f"{body}\n🔗 Log: {log_url}"
    return body


def main():
    semgrep_line, semgrep_high = summarize_semgrep()
    trivy_line, trivy_high = summarize_trivy()
    govuln_line, govuln_high = summarize_govulncheck()
    zap_line, zap_high = summarize_zap()

    high_total = semgrep_high + trivy_high + govuln_high + zap_high
    lines = [semgrep_line, trivy_line, govuln_line, zap_line]
    message = build_message(lines, high_total)
    status = "failure" if high_total > 0 else "success"

    # Immer in die Build-Logs schreiben (auch wenn pipepush fehlt).
    print(message)

    server = os.environ.get("PIPEPUSH_SERVER")
    token = os.environ.get("PIPEPUSH_TOKEN")
    if not server or not token:
        print(
            "PIPEPUSH_SERVER/PIPEPUSH_TOKEN nicht gesetzt — "
            "Benachrichtigung übersprungen.",
            file=sys.stderr,
        )
        return

    payload = {
        "token": token,
        "status": status,
        "pipeline": "security-scan",
        "branch": os.environ.get("BITBUCKET_BRANCH", "main"),
        "commit": os.environ.get("BITBUCKET_COMMIT", ""),
        "runId": os.environ.get("BITBUCKET_BUILD_NUMBER", ""),
        "message": message,
    }

    if requests is None:
        print("warn: 'requests' nicht verfügbar — Benachrichtigung übersprungen.",
              file=sys.stderr)
        return
    try:
        resp = requests.post(
            f"{server.rstrip('/')}/api/webhook",
            json=payload,
            timeout=15,
        )
        resp.raise_for_status()
        print(f"pipepush: benachrichtigt (status={status}, HTTP {resp.status_code}).")
    except Exception as exc:  # Notify-Fehler darf die Pipeline nicht rot machen
        print(f"warn: pipepush-Benachrichtigung fehlgeschlagen: {exc}",
              file=sys.stderr)


if __name__ == "__main__":
    main()

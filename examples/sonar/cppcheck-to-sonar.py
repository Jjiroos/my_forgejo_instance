#!/usr/bin/env python3
"""Convertit un rapport cppcheck XML v2 au format « generic issue » de SonarQube."""
import sys, json, xml.etree.ElementTree as ET

SEVERITY = {"error": "HIGH", "warning": "MEDIUM", "style": "LOW",
            "performance": "LOW", "portability": "LOW", "information": "INFO"}
QUALITY  = {"error": "RELIABILITY", "warning": "RELIABILITY", "style": "MAINTAINABILITY",
            "performance": "MAINTAINABILITY", "portability": "MAINTAINABILITY",
            "information": "MAINTAINABILITY"}

root = ET.parse(sys.argv[1]).getroot()
rules, issues, seen = [], [], set()

for err in root.iter("error"):
    rid, sev = err.get("id"), err.get("severity", "warning")
    loc = err.find("location")
    if loc is None:
        continue
    if rid not in seen:
        seen.add(rid)
        rules.append({
            "id": f"cppcheck:{rid}", "name": rid,
            "description": err.get("verbose") or err.get("msg") or rid,
            "engineId": "cppcheck", "cleanCodeAttribute": "LOGICAL",
            "impacts": [{"softwareQuality": QUALITY.get(sev, "MAINTAINABILITY"),
                         "severity": SEVERITY.get(sev, "MEDIUM")}],
        })
    issues.append({
        "ruleId": f"cppcheck:{rid}", "effortMinutes": 10,
        "primaryLocation": {
            "message": err.get("msg", rid),
            "filePath": loc.get("file"),
            "textRange": {"startLine": max(1, int(loc.get("line", 1)))},
        },
    })

json.dump({"rules": rules, "issues": issues}, open(sys.argv[2], "w"), indent=2)
print(f"{len(issues)} problème(s), {len(rules)} règle(s) → {sys.argv[2]}")

"""Adds a freshly built app version to source.json (AltStore / SideStore / Feather format).

usage: update_source.py <app_folder> <version> <build> <ipa_path> <download_url> <notes>
"""
import json
import os
import sys
from datetime import datetime, timezone

app_folder, version, build, ipa_path, download_url, notes = sys.argv[1:7]
repo = os.environ["GITHUB_REPOSITORY"]
raw = f"https://raw.githubusercontent.com/{repo}/main"

with open(f"apps/{app_folder}/app.json", encoding="utf-8") as f:
    meta = json.load(f)
with open("source.json", encoding="utf-8") as f:
    source = json.load(f)

source["iconURL"] = f"{raw}/icon.png"
source["website"] = f"https://github.com/{repo}"

app = next((a for a in source["apps"] if a["bundleIdentifier"] == meta["bundleIdentifier"]), None)
if app is None:
    app = {"versions": []}
    source["apps"].append(app)

size = os.path.getsize(ipa_path)
date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
entry = {
    "version": version,
    "buildVersion": build,
    "date": date,
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": size,
    "minOSVersion": meta.get("minOSVersion", "26.0"),
}

app.update({
    "name": meta["name"],
    "bundleIdentifier": meta["bundleIdentifier"],
    "developerName": meta["developerName"],
    "subtitle": meta["subtitle"],
    "localizedDescription": meta["localizedDescription"],
    "iconURL": f"{raw}/apps/{app_folder}/icon.png",
    "tintColor": meta.get("tintColor", "#FF8C00"),
    "category": meta.get("category", "other"),
    "screenshots": meta.get("screenshots", []),
    "appPermissions": {"entitlements": [], "privacy": meta.get("privacy", {})},
    # Legacy top-level fields: older stores and many signer apps read these.
    "version": version,
    "versionDate": date,
    "versionDescription": notes,
    "downloadURL": download_url,
    "size": size,
})
app["versions"] = [entry] + [v for v in app.get("versions", []) if v["version"] != version][:9]

with open("source.json", "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"source.json: {meta['name']} {version} ({size} bytes)")

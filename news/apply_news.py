"""Copies news/news.json into source.json["news"] (AltStore / SideStore news format).

Each item in news.json:
  identifier  unique id, never reuse (stores remember which ones they showed)
  title       headline
  caption     one or two lines under it
  date        "2026-11-15T19:30:00-05:00" (time shows in the store) or just "2026-11-15"
  image       optional: a file in news/images/ (turned into a full link), or a full https link
  appID       optional: bundle id, so tapping the news opens that app (e.g. com.mrlttec.homecontrol)
  url         optional: a web link to open instead
  tintColor   optional: card color, default MrLTTec brown
  notify      optional: true = some stores send a notification for it
  changes     optional: list of short lines ("what changed"), added under the caption as bullet points.
              Update it whenever an app gets a new version worth telling about.

Auto-updating posts: with an appID, "{version}" in identifier/title/caption becomes that app's newest version from
source.json, and "date": "{date}" becomes that version's build time. So every build refreshes the post by itself
(a new identifier per version makes stores show it as new).
"""
import json
import os

repo = os.environ.get("GITHUB_REPOSITORY", "Thecoolcool7891/MrLTTec-Apps")
raw = f"https://raw.githubusercontent.com/{repo}/main"

with open("news/news.json", encoding="utf-8") as f:
    items = json.load(f)
with open("source.json", encoding="utf-8") as f:
    source = json.load(f)

apps = {a.get("bundleIdentifier"): a for a in source.get("apps", [])}

news = []
for it in items:
    app = apps.get(it.get("appID"))
    if app:
        it = dict(it)
        ver = app.get("version", "")
        for k in ("identifier", "title", "caption"):
            if k in it:
                it[k] = it[k].replace("{version}", ver)
        if it.get("date") == "{date}":
            it["date"] = app.get("versionDate", "")
    if "{" in it["date"]:
        continue  # app not in the source yet
    caption = it.get("caption", "")
    changes = [c for c in it.get("changes", []) if c]
    if changes:
        nl = chr(10)
        caption = (caption + nl + nl if caption else "") + "What's new:" + nl + nl.join("• " + c for c in changes)
    n = {
        "title": it["title"],
        "identifier": it["identifier"],
        "caption": caption,
        "date": it["date"],
        "tintColor": it.get("tintColor", "#8B5A35"),
        "notify": bool(it.get("notify", False)),
    }
    img = it.get("image") or it.get("imageURL")
    if img:
        n["imageURL"] = img if img.startswith("http") else f"{raw}/news/images/{img}"
    if it.get("appID"):
        n["appID"] = it["appID"]
    if it.get("url"):
        n["url"] = it["url"]
    news.append(n)

news.sort(key=lambda n: n["date"], reverse=True)
source["news"] = news

with open("source.json", "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"source.json: {len(news)} news item(s)")

"""Downloads the web fonts Pupka uses (Google Fonts, OFL) as local woff2 files and writes fonts/fonts.css. Latin and Latin Extended only."""
import os, re, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "fonts")
CSS = "https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;0,6..72,600;0,6..72,700;1,6..72,400;1,6..72,600&family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500&family=Montserrat:ital,wght@0,400;0,500;0,600;0,700;1,400;1,600&family=Inter:wght@400;500;600;700&family=Shantell+Sans:wght@400;500;600;700&display=swap"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60).read()

os.makedirs(OUT, exist_ok=True)
css = get(CSS).decode("utf-8")
blocks = re.findall(r"/\* ([a-z-]+) \*/\s*(@font-face \{.*?\})", css, re.S)
names, out = {}, []
for subset, block in blocks:
    if subset not in ("latin", "latin-ext"):
        continue
    url = re.search(r"url\((https://[^)]+\.woff2)\)", block).group(1)
    if url not in names:
        family = re.search(r"font-family: '([^']+)'", block).group(1).replace(" ", "")
        style = re.search(r"font-style: (\w+)", block).group(1)
        name = f"{family}-{style}-{subset}-{len(names)}.woff2"
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(get(url))
        names[url] = name
    out.append(block.replace(url, names[url]))
with open(os.path.join(OUT, "fonts.css"), "w") as f:
    f.write("/* Fonts bundled for offline use (Google Fonts, SIL Open Font License). */\n" + "\n".join(out) + "\n")
print(len(names), "files,", len(out), "faces")

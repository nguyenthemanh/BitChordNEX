import re
raw = open(r"C:\Users\Dell\.cursor\projects\c-Users-Dell-DevEcoStudioProjects-BitChordNEX\agent-tools\d06eca23-6469-4bab-9fc9-8d4f222cac83.txt", encoding="utf-8", errors="ignore").read()
for match in re.finditer(r'"host": "([^"]*)"[\s\S]*?"scheme": "([^"]*)"', raw):
    host, scheme = match.group(1), match.group(2)
    blob = (host + " " + scheme).lower()
    if any(key in blob for key in ["sound", "volume", "audio", "ring", "tone", "effect"]):
        print(scheme + "://" + host)

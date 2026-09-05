from pathlib import Path
import json, re

imports = json.loads(Path("assets/resolved-imports.json").read_text())
lines = [
    "/* Generated from resolved-imports.json; inferred mappings retain provenance there. */",
    "typedef enum {",
]
patch = []
names = []
for index, x in enumerate(imports):
    name = x["exports"][0][1]
    if name in ["lstrcpy", "lstrcat"]:
        name += "A"
    if name.startswith("Rtl") and name in [
        "RtlAllocateHeap",
        "RtlReAllocateHeap",
        "RtlSizeHeap",
    ]:
        name = {
            "RtlAllocateHeap": "HeapAlloc",
            "RtlReAllocateHeap": "HeapReAlloc",
            "RtlSizeHeap": "HeapSize",
        }[name]
    token = re.sub("[^a-zA-Z0-9_]", "_", name)
    lines.append(f" API_{token}={index},")
    patch.append(f'wr(c,0x{x["iat"]:x},0xf0000000u+{index}*16,32);')
    names.append(name)
lines += (
    [" API_COUNT", "} API;", "static const char*api_names[]={"]
    + [json.dumps(n) + "," for n in names]
    + ["};", "static void patch_imports(CPU*c){"]
    + patch
    + ["}"]
)
Path("engine/generated/imports.h").write_text("\n".join(lines) + "\n")

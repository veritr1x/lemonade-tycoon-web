"""Ahead-of-time x86 -> C lifting of the supplied game's captured text section.
Each decoded instruction becomes C; dispatch only transfers between native blocks.
Unsupported instructions trap explicitly and are recorded for follow-up.
"""

from pathlib import Path
import json, struct, collections
from capstone import *
from capstone.x86 import *

BASE = 0x400000
LO = 0x401000
HI = 0x462000
b = Path("assets/cold-memory.bin").read_bytes()
c = Cs(CS_ARCH_X86, CS_MODE_32)
c.detail = True
c.skipdata = True
instructions = {i.address: i for i in c.disasm(b[LO - BASE : HI - BASE], LO)}
# Include direct branch targets that linear decoding might have missed in data.
pending = [
    int(address, 16)
    for address in json.loads(Path("assets/entry-points.json").read_text())
]
# Function pointers in initializer lists, vtables, and jump tables are entry points.
for offset in range(0, len(b) - 3, 4):
    target = struct.unpack_from("<I", b, offset)[0]
    if LO <= target < HI:
        pending.append(target)
for i in list(instructions.values()):
    if i.id:
        pending.extend(
            op.imm for op in i.operands if op.type == X86_OP_IMM and LO <= op.imm < HI
        )
while pending:
    addr = pending.pop()
    if addr in instructions or not LO <= addr < HI:
        continue
    for i in c.disasm(b[addr - BASE : HI - BASE], addr):
        if i.address in instructions:
            break
        instructions[i.address] = i
        if (
            i.id
            and (i.group(CS_GRP_JUMP) or i.group(CS_GRP_CALL))
            and i.operands[0].type == X86_OP_IMM
        ):
            pending.append(i.operands[0].imm)
        if i.mnemonic in ["ret", "jmp"] or not i.id:
            break
regs = {}
for full, lo, hi, word in [
    ("eax", "al", "ah", "ax"),
    ("ebx", "bl", "bh", "bx"),
    ("ecx", "cl", "ch", "cx"),
    ("edx", "dl", "dh", "dx"),
    ("esi", None, None, "si"),
    ("edi", None, None, "di"),
    ("ebp", None, None, "bp"),
    ("esp", None, None, "sp"),
]:
    regs[full] = (full, 0, 32)
    regs[word] = (full, 0, 16)
    if lo:
        regs[lo] = (full, 0, 8)
        regs[hi] = (full, 8, 8)


def rn(op):
    return c.reg_name(op.reg)


def rr(name):
    full, shift, bits = regs[name]
    return f"c->{full}" if bits == 32 else f"((c->{full}>>{shift})&{(1<<bits)-1}u)"


def rw(name, value):
    full, shift, bits = regs[name]
    return (
        f"c->{full}=({value});"
        if bits == 32
        else f"c->{full}=(c->{full}&~0x{((1<<bits)-1)<<shift:x}u)|((({value})&{(1<<bits)-1}u)<<{shift});"
    )


def address(op):
    m = op.mem
    terms = [f"0x{m.disp&0xffffffff:x}u"]
    if m.base:
        terms.append(rr(c.reg_name(m.base)))
    if m.index:
        terms.append(f"({rr(c.reg_name(m.index))}*{m.scale}u)")
    if m.segment and c.reg_name(m.segment) == "fs":
        terms.append("c->fsbase")
    return "(uint32_t)(" + "+".join(terms) + ")"


def read(op):
    if op.type == X86_OP_REG:
        return rr(rn(op))
    if op.type == X86_OP_IMM:
        return f"0x{op.imm&0xffffffff:x}u"
    if op.type == X86_OP_MEM:
        return f"rd(c,{address(op)},{op.size*8})"
    raise ValueError("operand")


def write(op, v):
    if op.type == X86_OP_REG:
        return rw(rn(op), v)
    if op.type == X86_OP_MEM:
        return f"wr(c,{address(op)},{v},{op.size*8});"
    raise ValueError("destination")


def fop(op):
    if op.type == X86_OP_REG:
        return "fr(c," + str(op.reg - X86_REG_ST0) + ")"
    return f"rdf(c,{address(op)},{op.size*8})"


conds = {
    "e": "c->zf",
    "ne": "!c->zf",
    "a": "!c->cf&&!c->zf",
    "ae": "!c->cf",
    "b": "c->cf",
    "be": "c->cf||c->zf",
    "g": "!c->zf&&(c->sf==c->of)",
    "ge": "c->sf==c->of",
    "l": "c->sf!=c->of",
    "le": "c->zf||(c->sf!=c->of)",
    "s": "c->sf",
    "ns": "!c->sf",
    "o": "c->of",
    "no": "!c->of",
    "p": "c->pf",
    "np": "!c->pf",
}
unsupported = collections.Counter()


def lift(i, page):
    m = i.mnemonic
    ops = i.operands if i.id else []
    nxt = i.address + i.size

    def jump(a):
        if page <= a < page + 4096 and a in instructions:
            return f"goto L{a:x};"
        return f"return 0x{a:x}u;"

    end = jump(nxt)
    if m in ["nop", "wait", "fnclex"]:
        return end
    if m == "mov":
        return write(ops[0], read(ops[1])) + end
    if m == "lea":
        return write(ops[0], address(ops[1])) + end
    if m == "movzx":
        return write(ops[0], read(ops[1])) + end
    if m == "movsx":
        return write(ops[0], f"sx({read(ops[1])},{ops[1].size*8})") + end
    if m == "push":
        return f"push(c,{read(ops[0])});" + end
    if m == "pop":
        return "uint32_t v=pop(c);" + write(ops[0], "v") + end
    if m == "leave":
        return "c->esp=c->ebp;c->ebp=pop(c);" + end
    if m == "ret":
        return (
            "uint32_t pc=pop(c);"
            + (f"c->esp+={ops[0].imm};" if ops else "")
            + "return pc;"
        )
    if m in ["jmp", "call"]:
        text = f"push(c,0x{nxt:x});" if m == "call" else ""
        if ops[0].type == X86_OP_IMM:
            return text + jump(ops[0].imm)
        return f"uint32_t target={read(ops[0])};" + text + "return target;"
    if m.startswith("j") and m[1:] in conds:
        return f"if({conds[m[1:]]}){{{jump(ops[0].imm)}}}" + end
    if m == "jecxz":
        return f"if(c->ecx==0){{{jump(ops[0].imm)}}}" + end
    if m.startswith("set") and m[3:] in conds:
        return write(ops[0], f"({conds[m[3:]]})") + end
    if m in ["add", "sub", "adc", "sbb", "and", "or", "xor", "cmp", "test"]:
        op = {
            "add": 0,
            "sub": 1,
            "adc": 2,
            "sbb": 3,
            "and": 4,
            "or": 5,
            "xor": 6,
            "cmp": 1,
            "test": 4,
        }[m]
        text = f"uint32_t v=alu(c,{read(ops[0])},{read(ops[1])},{ops[0].size*8},{op});"
        return text + ("" if m in ["cmp", "test"] else write(ops[0], "v")) + end
    if m in ["inc", "dec", "lock inc"]:
        return (
            f'uint32_t cf=c->cf;uint32_t v=alu(c,{read(ops[0])},1,{ops[0].size*8},{1 if m=="dec" else 0});c->cf=cf;'
            + write(ops[0], "v")
            + end
        )
    if m == "not":
        return write(ops[0], f"~({read(ops[0])})") + end
    if m == "neg":
        return (
            f"uint32_t v=alu(c,0,{read(ops[0])},{ops[0].size*8},1);"
            + write(ops[0], "v")
            + end
        )
    if m in ["shl", "sal", "shr", "sar", "rol", "ror"]:
        kind = {"shl": 0, "sal": 0, "shr": 1, "sar": 2, "rol": 3, "ror": 4}[m]
        return (
            f"uint32_t v=shift(c,{read(ops[0])},{read(ops[1])},{ops[0].size*8},{kind});"
            + write(ops[0], "v")
            + end
        )
    if m == "cdq":
        return "c->edx=(uint32_t)((int32_t)c->eax>>31);" + end
    if m == "cwde":
        return "c->eax=sx(c->eax,16);" + end
    if m == "imul" and len(ops) > 1:
        a = ops[0] if len(ops) == 2 else ops[1]
        bv = ops[1] if len(ops) == 2 else ops[2]
        n = ops[0].size * 8
        return (
            f"int64_t v=(int64_t)sx({read(a)},{n})*sx({read(bv)},{n});c->cf=c->of=(v!=sx(v,{n}));"
            + write(ops[0], "v")
            + end
        )
    if m in ["imul", "mul"] and ops[0].size == 4:
        sign = m == "imul"
        v = (
            f"(int64_t)(int32_t)c->eax*(int32_t){read(ops[0])}"
            if sign
            else f"(uint64_t)c->eax*{read(ops[0])}"
        )
        return (
            f"uint64_t v={v};c->eax=v;c->edx=v>>32;c->cf=c->of="
            + ("(int64_t)v!=(int64_t)(int32_t)c->eax;" if sign else "c->edx!=0;")
            + end
        )
    if m in ["div", "idiv"] and ops[0].size == 4:
        typ = "int64_t" if m == "idiv" else "uint64_t"
        den = f"(int32_t){read(ops[0])}" if m == "idiv" else read(ops[0])
        bound = "q<INT32_MIN||q>INT32_MAX" if m == "idiv" else "q>UINT32_MAX"
        return (
            f"{typ} a=((uint64_t)c->edx<<32)|c->eax;{typ} d={den};if(!d"
            + ("||(a==INT64_MIN&&d==-1)" if m == "idiv" else "")
            + f"){{fault(c,0x{i.address:x});return 0;}}{typ} q=a/d;if({bound}){{fault(c,0x{i.address:x});return 0;}}c->eax=q;c->edx=a%d;"
            + end
        )
    if m == "xchg":
        return (
            f"uint32_t a={read(ops[0])},b={read(ops[1])};"
            + write(ops[0], "b")
            + write(ops[1], "a")
            + end
        )
    if m in ["cld", "std", "clc", "stc", "cmc"]:
        return {
            "cld": "c->df=0;",
            "std": "c->df=1;",
            "clc": "c->cf=0;",
            "stc": "c->cf=1;",
            "cmc": "c->cf^=1;",
        }[m] + end
    if m == "sahf":
        return (
            "uint32_t v=c->eax>>8;c->sf=(v>>7)&1;c->zf=(v>>6)&1;c->af=(v>>4)&1;c->pf=(v>>2)&1;c->cf=v&1;"
            + end
        )
    if m == "xlatb":
        return rw("al", "rd(c,c->ebx+(c->eax&255),8)") + end
    root = m.split()[-1]
    if root in ["movsb", "movsw", "movsd", "stosb", "stosw", "stosd", "scasb", "cmpsb"]:
        width = {"b": 1, "w": 2, "d": 4}[root[-1]]
        rep = m.startswith("rep")
        text = "uint32_t count=" + ("c->ecx;" if rep else "1;")
        text += f"uint32_t iterations=0;while(count--){{if(c->fault||++iterations>c->mem_size/{width}){{fault(c,0x{i.address:x});return 0;}}int32_t d=c->df?-{width}:{width};"
        if root.startswith("movs"):
            text += (
                f"wr(c,c->edi,rd(c,c->esi,{width*8}),{width*8});c->esi+=d;c->edi+=d;"
            )
        elif root.startswith("stos"):
            text += f"wr(c,c->edi,c->eax,{width*8});c->edi+=d;"
        elif root == "scasb":
            text += "alu(c,c->eax,rd(c,c->edi,8),8,1);c->edi+=d;"
        else:
            text += "alu(c,rd(c,c->esi,8),rd(c,c->edi,8),8,1);c->esi+=d;c->edi+=d;"
        if rep:
            text += "c->ecx--;"
        if m.startswith("repne"):
            text += "if(c->zf)break;"
        if m.startswith("repe"):
            text += "if(!c->zf)break;"
        return text + "}" + end
    if m in ["fld", "fild"]:
        val = (
            fop(ops[0])
            if m == "fld"
            else (
                f"(int64_t)rd(c,{address(ops[0])},64)"
                if ops[0].size == 8
                else f"sx({read(ops[0])},{ops[0].size*8})"
            )
        )
        return f"fpush(c,{val});" + end
    if m in ["fldz", "fld1"]:
        return f'fpush(c,{0 if m=="fldz" else 1});' + end
    if m in ["fst", "fstp"]:
        text = (
            f"fw(c,{ops[0].reg-X86_REG_ST0},fr(c,0));"
            if ops[0].type == X86_OP_REG
            else f"wrf(c,{address(ops[0])},fr(c,0),{ops[0].size*8});"
        )
        return text + ("fpop(c);" if m == "fstp" else "") + end
    if m in [
        "fmul",
        "fdiv",
        "fdivr",
        "fadd",
        "fsub",
        "fsubr",
        "fmulp",
        "fdivp",
        "fsubp",
        "faddp",
        "fidiv",
    ]:
        dest = 0
        other = fop(ops[-1]) if ops else "fr(c,0)"
        if len(ops) == 2:
            dest = ops[0].reg - X86_REG_ST0
        elif m.endswith("p"):
            dest = 1
        if m == "fidiv":
            other = f"sx({read(ops[0])},{ops[0].size*8})"
        lhs = f"fr(c,{dest})"
        rhs = other
        if m.endswith("r"):
            lhs, rhs = rhs, lhs
        op = "*" if "mul" in m else "/" if "div" in m else "-" if "sub" in m else "+"
        return (
            f"fw(c,{dest},{lhs}{op}{rhs});"
            + ("fpop(c);" if m.endswith("p") else "")
            + end
        )
    if m == "fchs":
        return "fw(c,0,-fr(c,0));" + end
    if m in ["fcom", "fcomp"]:
        return (
            f"double a=fr(c,0),b={fop(ops[0])};c->fsw&=~0x4500;if(isnan(a)||isnan(b))c->fsw|=0x4500;else if(a<b)c->fsw|=0x100;else if(a==b)c->fsw|=0x4000;"
            + ("fpop(c);" if m == "fcomp" else "")
            + end
        )
    if m in ["fnstcw", "fldcw", "fnstsw"]:
        return (
            write(ops[0], "c->fcw")
            if m == "fnstcw"
            else (
                "c->fcw=" + read(ops[0]) + ";"
                if m == "fldcw"
                else write(ops[0], "c->fsw")
            )
        ) + end
    if m == "fistp":
        return (
            "double v=fr(c,0);int mode=(c->fcw>>10)&3;int64_t iv=(int64_t)(mode==3?trunc(v):mode==1?floor(v):mode==2?ceil(v):nearbyint(v));"
            + write(ops[0], "iv")
            + "fpop(c);"
            + end
        )
    unsupported[m] += 1
    return f"fault(c,0x{i.address:x});return 0;"


out = Path("native/generated")
out.mkdir(exist_ok=True)
pages = collections.defaultdict(list)
for i in instructions.values():
    pages[i.address & ~4095].append(i)
for page, entries in sorted(pages.items()):
    entries.sort(key=lambda i: i.address)
    lines = [
        '#include "../runtime.h"',
        f"uint32_t page_{page:x}(CPU*c,uint32_t pc){{",
        "switch(pc){",
    ]
    lines += [f"case 0x{i.address:x}:goto L{i.address:x};" for i in entries]
    lines += ["default:fault(c,pc);return 0;}"]
    for i in entries:
        try:
            body = lift(i, page)
        except (KeyError, ValueError, IndexError) as e:
            unsupported[i.mnemonic] += 1
            body = f"fault(c,0x{i.address:x});return 0;"
        # The original text editor's activation/deactivation drives the host keyboard.
        # The reference/differential host uses a no-op observer.
        if i.address in (0x437160, 0x437180):
            body = (
                f"native_text_focus(c,c->ecx,{1 if i.address==0x437160 else 0});" + body
            )
        lines.append(
            f"L{i.address:x}:{{if(c->fault||++c->steps>c->limit){{fault(c,0x{i.address:x});return 0;}}/* {i.mnemonic} {i.op_str} */{body}}}"
        )
    lines += ["}"]
    (out / f"page_{page:x}.c").write_text("\n".join(lines) + "\n")
lines = ['#include "../runtime.h"'] + [
    f"extern uint32_t page_{p:x}(CPU*,uint32_t);" for p in sorted(pages)
]
lines += (
    ["uint32_t game_dispatch(CPU*c,uint32_t pc){switch(pc&~4095u){"]
    + [f"case 0x{p:x}:return page_{p:x}(c,pc);" for p in sorted(pages)]
    + ["default:return native_api(c,pc);}}"]
)
(out / "dispatch.c").write_text("\n".join(lines) + "\n")
report = dict(
    instructions=len(instructions),
    pages=len(pages),
    unsupported=dict(unsupported),
    input="assets/cold-memory.bin",
    limitations=[
        "x87 uses host double; extended precision is not yet modeled",
        "unsupported instructions trap; reachability is not yet established",
        "platform adapters are incomplete; see docs/architecture.md",
        "code input is the cold startup image",
    ],
)
(out / "coverage.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))

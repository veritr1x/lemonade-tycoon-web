"""Compare native C translations with the supplied original x86 routines.
Uses Unicorn only as a development-time oracle, never in the native runtime.
"""

import ctypes as C, json, random, struct, platform
from pathlib import Path
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32
from unicorn import x86_const as R


class CPU(C.Structure):
    _fields_ = [
        (n, C.c_uint32)
        for n in "eax ecx edx ebx esp ebp esi edi cf pf af zf sf of df fsbase fault steps limit".split()
    ] + [
        ("fp", C.c_double * 8),
        ("top", C.c_int),
        ("fcw", C.c_uint16),
        ("fsw", C.c_uint16),
        ("mem", C.POINTER(C.c_uint8)),
        ("mem_size", C.c_size_t),
        ("halted", C.c_uint32),
        ("exit_code", C.c_uint32),
    ]


library = "liblemonade.dylib" if platform.system() == "Darwin" else "liblemonade.so"
lib = C.CDLL(str((Path("build/native") / library).resolve()))
lib.game_run.argtypes = [C.POINTER(CPU), C.c_uint32, C.c_uint32]
lib.game_run.restype = C.c_int
# Both hosts use the CPU struct from runtime.h; generated code remains ordinary C.
SIZE = 0x1000000
BASE = 0x400000
OBJ = 0x900000
STACK = 0xE00000
STOP = 0xF00000
memory = (C.c_uint8 * SIZE)()
image = Path("assets/cold-memory.bin").read_bytes()
C.memmove(C.addressof(memory) + BASE, image, len(image))
u = Uc(UC_ARCH_X86, UC_MODE_32)
u.mem_map(0, SIZE)
u.mem_write(BASE, image)
rng = random.Random(0x1EADE)
tests = 0
regs = "eax ecx edx ebx esp ebp esi edi".split()


def run(entry, patches, args=(), inspect=()):
    global tests
    cpu = CPU()
    cpu.mem = memory
    cpu.mem_size = SIZE
    cpu.limit = 100000
    cpu.fcw = 0x37F
    cpu.eax = rng.getrandbits(32)
    cpu.ebx = rng.getrandbits(32)
    cpu.edx = rng.getrandbits(32)
    cpu.esi = rng.getrandbits(32)
    cpu.edi = rng.getrandbits(32)
    cpu.ebp = STACK + 0x100
    cpu.esp = STACK
    cpu.ecx = OBJ
    for name in regs:
        u.reg_write(getattr(R, "UC_X86_REG_" + name.upper()), getattr(cpu, name))
    u.reg_write(R.UC_X86_REG_EFLAGS, 0x202)
    u.reg_write(R.UC_X86_REG_FPCW, 0x37F)
    u.reg_write(R.UC_X86_REG_FPSW, 0)
    for i in range(8):
        u.reg_write(getattr(R, "UC_X86_REG_FP" + str(i)), (0, 0))
    patches = list(patches) + [
        (
            STACK,
            struct.pack(
                "<" + "I" * (1 + len(args)), STOP, *[a & 0xFFFFFFFF for a in args]
            ),
        )
    ]
    for address, data in patches:
        u.mem_write(address, data)
        C.memmove(C.addressof(memory) + address, data, len(data))
    u.emu_start(entry, STOP, count=100000)
    assert u.reg_read(R.UC_X86_REG_EIP) == STOP, f"Original did not return: {entry:x}"
    result = lib.game_run(C.byref(cpu), entry, STOP)
    assert result == 0, f"Native fault {cpu.fault:x} from {entry:x}"
    for name in regs:
        actual = getattr(cpu, name)
        expected = u.reg_read(getattr(R, "UC_X86_REG_" + name.upper()))
        assert actual == expected, f"{entry:x} {name}: {actual:x} != {expected:x}"
    for address, n in inspect:
        actual = bytes(memory[address : address + n])
        expected = bytes(u.mem_read(address, n))
        assert (
            actual == expected
        ), f"{entry:x} memory {address:x}: {actual.hex()} != {expected.hex()}"
    tests += 1


# Original money/profit/date methods: negative values, zero-revenue branches,
# wraparound, signed division, stack arguments, and callee stack cleanup.
methods = [
    0x406FFD,
    0x407011,
    0x40701A,
    0x407038,
    0x40703F,
    0x40704E,
    0x407052,
    0x407056,
    0x40705A,
    0x40706E,
    0x407081,
    0x40708A,
    0x407094,
    0x40709E,
    0x4070A8,
]
for n in range(160):
    values = [rng.randint(-2000000, 2000000) for _ in range(6)]
    if n % 8 == 0:
        values[0] = 0
    values[5] = (
        [0, 1, 29, 30, 359, 360, 361, 719, 720, 721][n % 10]
        if n < 100
        else rng.randint(-100000, 100000)
    )
    data = struct.pack("<6i", *values)
    for entry in methods:
        run(entry, [(OBJ, data)], args=[rng.getrandbits(32)], inspect=[(OBJ, 24)])
# Original floating point parameter initialization, including products that
# must round to the exact same stored IEEE binary32 value.
for n in range(400):
    a, b = [rng.uniform(-10000, 10000) for _ in range(2)]
    patches = [
        (0x462338, struct.pack("<f", a)),
        (0x462520, struct.pack("<f", b)),
        (0x478F50, b"\0" * 4),
    ]
    run(0x401000, patches, inspect=[(0x478F50, 4)])
# A multi-call original method updates three independent accounting records.
for n in range(200):
    values = [rng.getrandbits(32) for _ in range(0x500 // 4)]
    run(
        0x402943,
        [(OBJ, struct.pack("<" + "I" * len(values), *values))],
        args=[rng.getrandbits(32)],
        inspect=[(OBJ, 0x500)],
    )
# Original byte/block copying and zeroing over unaligned lengths and boundaries.
for n in [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 63, 64, 255, 256, 1023]:
    data = bytes(rng.getrandbits(8) for _ in range(2048))
    run(0x42ED80, [(OBJ, data)], args=[OBJ + 3, n], inspect=[(OBJ, 2048)])
    run(
        0x42EDA0,
        [(OBJ, data), (OBJ + 0x1000, bytes(2048))],
        args=[OBJ + 0x1003, OBJ + 1, n],
        inspect=[(OBJ + 0x1000, 2048)],
    )
# Original reverse string search exercises repne scasb with ECX=0xffffffff.
for n in range(100):
    data = bytes(rng.choice(b"abc/def.xyz") for _ in range(n)) + b"\0"
    run(0x453A50, [(OBJ, data)], args=[OBJ, ord("/")], inspect=[(OBJ, len(data))])
# Compare the accelerated row-copy boundary against every original instruction.
# Include odd addresses, a one-pixel row, identical spans, and arbitrary incoming
# flags. Check all registers, flags, pixels, guard bytes, and instruction counts.
lib.game_dispatch.argtypes = [C.POINTER(CPU), C.c_uint32]
lib.game_dispatch.restype = C.c_uint32
flag_bits = dict(cf=0, pf=2, af=4, zf=6, sf=7, df=10, of=11)
for case in range(500):
    count = [1, 2, 3, 31, 320, 640, 1024][case % 7]
    source = OBJ + 16 + case % 4
    destination = source if case % 5 == 0 else OBJ + 4096 + case % 3
    data = bytes(rng.getrandbits(8) for _ in range(8192))
    C.memmove(C.addressof(memory) + OBJ, data, len(data))
    u.mem_write(OBJ, data)
    cpu = CPU()
    cpu.mem, cpu.mem_size = memory, SIZE
    for name in regs:
        setattr(cpu, name, rng.getrandbits(32))
    cpu.eax, cpu.edi, cpu.ebp = 2, 1, count
    cpu.ebx, cpu.edx = source, destination - 2
    cpu.steps = rng.randrange(10000)
    expected_steps = cpu.steps + 7 * count - 3
    cpu.limit = expected_steps
    flags = 0x202
    for name, bit in flag_bits.items():
        value = rng.randrange(2)
        setattr(cpu, name, value)
        flags |= value << bit
    for name in regs:
        u.reg_write(getattr(R, "UC_X86_REG_" + name.upper()), getattr(cpu, name))
    u.reg_write(R.UC_X86_REG_EFLAGS, flags)
    u.emu_start(0x434001, 0x434009, count=10000)
    assert u.reg_read(R.UC_X86_REG_EIP) == 0x434009
    assert lib.game_dispatch(C.byref(cpu), 0x434001) == 0x434009
    assert cpu.steps == expected_steps and not cpu.fault
    for name in regs:
        assert getattr(cpu, name) == u.reg_read(
            getattr(R, "UC_X86_REG_" + name.upper())
        ), name
    flags = u.reg_read(R.UC_X86_REG_EFLAGS)
    for name, bit in flag_bits.items():
        assert getattr(cpu, name) == (flags >> bit) & 1, name
    assert bytes(memory[OBJ : OBJ + len(data)]) == bytes(u.mem_read(OBJ, len(data)))
    tests += 1

# The keyed sprite row leaves transparent pixels untouched and maps visible
# pixels through a 16-bit palette. Compare both branch paths and the last EBP.
lib.lemon_test_palette_span.argtypes = [C.POINTER(CPU)]
lib.lemon_test_palette_span.restype = C.c_int
palette = OBJ + 0x10000
palette_data = bytes(rng.getrandbits(8) for _ in range(131072))
C.memmove(C.addressof(memory) + palette, palette_data, len(palette_data))
u.mem_write(palette, palette_data)
for case in range(500):
    count = [1, 2, 31, 320, 640, 1024][case % 6]
    key = rng.getrandbits(16)
    values = [
        key if case % 3 == 0 or rng.randrange(3) == 0 else rng.getrandbits(16)
        for _ in range(count)
    ]
    data = bytearray(rng.getrandbits(8) for _ in range(8192))
    source, destination = OBJ + 3, OBJ + 4097
    data[3 : 3 + count * 2] = struct.pack("<" + "H" * count, *values)
    C.memmove(C.addressof(memory) + OBJ, bytes(data), len(data))
    u.mem_write(OBJ, bytes(data))
    stack_data = bytearray(64)
    struct.pack_into("<H", stack_data, 0x10, key)
    struct.pack_into("<I", stack_data, 0x14, palette)
    struct.pack_into("<I", stack_data, 0x20, 1)
    C.memmove(C.addressof(memory) + STACK, bytes(stack_data), len(stack_data))
    u.mem_write(STACK, bytes(stack_data))
    cpu = CPU()
    cpu.mem, cpu.mem_size = memory, SIZE
    for name in regs:
        setattr(cpu, name, rng.getrandbits(32))
    cpu.eax, cpu.ecx, cpu.ebx, cpu.edi, cpu.esp = count, 2, source, destination, STACK
    cpu.steps, cpu.limit = 123, 123 + 13 * count
    flags = 0x202
    for name, bit in flag_bits.items():
        value = rng.randrange(2)
        setattr(cpu, name, value)
        flags |= value << bit
    for name in regs:
        u.reg_write(getattr(R, "UC_X86_REG_" + name.upper()), getattr(cpu, name))
    u.reg_write(R.UC_X86_REG_EFLAGS, flags)
    u.emu_start(0x4346B5, 0x4346DE, count=20000)
    assert u.reg_read(R.UC_X86_REG_EIP) == 0x4346DE
    assert lib.lemon_test_palette_span(C.byref(cpu))
    assert cpu.steps == 123 + count * 9 + sum(v != key for v in values) * 4
    for name in regs:
        assert getattr(cpu, name) == u.reg_read(
            getattr(R, "UC_X86_REG_" + name.upper())
        ), name
    flags = u.reg_read(R.UC_X86_REG_EFLAGS)
    for name, bit in flag_bits.items():
        assert getattr(cpu, name) == (flags >> bit) & 1, name
    assert bytes(memory[OBJ : OBJ + len(data)]) == bytes(u.mem_read(OBJ, len(data)))
    assert bytes(memory[STACK : STACK + 64]) == bytes(u.mem_read(STACK, 64))
    assert bytes(memory[palette : palette + 131072]) == bytes(
        u.mem_read(palette, 131072)
    )
    tests += 1

report = dict(
    result="passed",
    cases=tests,
    host=platform.machine(),
    oracle="Original x86 routines executed by Unicorn",
    native="Ahead-of-time compiled host shared library",
    scope="15 original accounting/date routines, original parameter multiplication, a multi-call accounting update, block copying/clearing, reverse string search, and accelerated pixel rows",
    limitations="Does not validate whole-game behavior, all translated instructions, platform APIs, UI, or iOS execution",
)
Path("build/tests/differential.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))

#!/usr/bin/env python3
"""Fabrique des mini-jeux de test (fait maison, aucun téléchargement).

Chaque jeu remplit l'écran en bleu, et en rouge tant que le bouton A est appuyé
(sauf PS1 : écran bleu fixe). De quoi vérifier qu'un moteur démarre, affiche une
image et reçoit les boutons.
"""
import os
import struct
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "roms"
os.makedirs(OUT, exist_ok=True)


class Asm:
    """Assembleur minimal : octets bruts + étiquettes + corrections en 2e passe."""

    def __init__(self, origin):
        self.origin = origin
        self.code = bytearray()
        self.labels = {}
        self.fixups = []  # (position, étiquette, fonction de calcul)

    @property
    def pc(self):
        return self.origin + len(self.code)

    def label(self, name):
        self.labels[name] = self.pc

    def emit(self, *data):
        for d in data:
            self.code += bytes([d]) if isinstance(d, int) else d

    def ref(self, size, name, compute):
        self.fixups.append((len(self.code), size, name, compute))
        self.code += bytes(size)

    def resolve(self):
        for pos, size, name, compute in self.fixups:
            value = compute(self.labels[name], self.origin + pos)
            self.code[pos:pos + size] = value
        return bytes(self.code)


# ---------------------------------------------------------------- NES (6502)
def nes():
    a = Asm(0xC000)
    abs16 = lambda target, here: struct.pack("<H", target)
    rel8 = lambda target, here: struct.pack("<b", target - (here + 1))

    def op_abs(opcode, address): a.emit(opcode, *struct.pack("<H", address))
    def branch(opcode, name): a.emit(opcode); a.ref(1, name, rel8)

    a.label("reset")
    a.emit(0x78, 0xD8)                         # SEI ; CLD
    a.emit(0xA2, 0x40); op_abs(0x8E, 0x4017)   # LDX #$40 ; STX $4017
    a.emit(0xA2, 0xFF, 0x9A, 0xE8)             # LDX #$FF ; TXS ; INX
    op_abs(0x8E, 0x2000); op_abs(0x8E, 0x2001); op_abs(0x8E, 0x4010)
    for n in ("vb1", "vb2"):
        a.label(n); op_abs(0x2C, 0x2002); branch(0x10, n)   # BIT $2002 ; BPL
    a.emit(0xA9, 0x3F); op_abs(0x8D, 0x2006)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2006)
    a.emit(0xA9, 0x12); op_abs(0x8D, 0x2007)   # couleur de fond : bleu
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2005); op_abs(0x8D, 0x2005)
    a.emit(0xA9, 0x80); op_abs(0x8D, 0x2000)   # NMI activée
    a.emit(0xA9, 0x0A); op_abs(0x8D, 0x2001)   # affichage du fond
    a.label("loop"); a.emit(0x4C); a.ref(2, "loop", abs16)

    a.label("nmi")
    a.emit(0x48)                               # PHA
    a.emit(0xA9, 0x01); op_abs(0x8D, 0x4016)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x4016)
    op_abs(0xAD, 0x4016); a.emit(0x29, 0x01)   # LDA $4016 ; AND #1 (bouton A)
    branch(0xF0, "notA")
    a.emit(0xA2, 0x16); a.emit(0x4C); a.ref(2, "write", abs16)   # rouge
    a.label("notA"); a.emit(0xA2, 0x12)                          # bleu
    a.label("write")
    op_abs(0xAD, 0x2002)
    a.emit(0xA9, 0x3F); op_abs(0x8D, 0x2006)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2006)
    op_abs(0x8E, 0x2007)                       # STX $2007
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2005); op_abs(0x8D, 0x2005)
    a.emit(0xA9, 0x80); op_abs(0x8D, 0x2000)
    a.emit(0x68, 0x40)                         # PLA ; RTI
    a.label("irq"); a.emit(0x40)
    code = a.resolve()

    prg = bytearray(0x4000)
    prg[:len(code)] = code
    prg[0x3FFA:0x4000] = struct.pack("<HHH", a.labels["nmi"], a.labels["reset"], a.labels["irq"])
    header = b"NES\x1a" + bytes([1, 1, 0, 0]) + bytes(8)
    return header + bytes(prg) + bytes(0x2000)


# ------------------------------------------------------------ Game Boy (SM83)
NINTENDO_LOGO_GB = bytes.fromhex(
    "CEED6666CC0D000B03730083000C000D0008111F8889000EDCCC6EE6DDDDD999BBBB67636E0EECCCDDDC999FBBB9333E")


def gameboy():
    a = Asm(0x150)
    rel8 = lambda target, here: struct.pack("<b", target - (here + 1))

    def jr(opcode, name): a.emit(opcode); a.ref(1, name, rel8)

    a.emit(0xF3, 0x31, 0xFE, 0xFF)             # DI ; LD SP,$FFFE
    a.label("wait"); a.emit(0xF0, 0x44, 0xFE, 144); jr(0x38, "wait")   # attendre la VBlank
    a.emit(0xAF, 0xE0, 0x40)                   # XOR A ; LDH ($40),A  (écran éteint)
    a.emit(0x21, 0x00, 0x80, 0x01, 0x00, 0x20) # LD HL,$8000 ; LD BC,$2000
    a.label("clear"); a.emit(0xAF, 0x22, 0x0B, 0x78, 0xB1); jr(0x20, "clear")
    a.emit(0xAF, 0xE0, 0x47)                   # BGP = 0 (blanc)
    a.emit(0x3E, 0x91, 0xE0, 0x40)             # écran allumé
    a.label("main")
    a.emit(0x3E, 0x10, 0xE0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xE6, 0x01)
    jr(0x28, "pressed")
    a.emit(0xAF, 0xE0, 0x47); jr(0x18, "main")
    a.label("pressed"); a.emit(0x3E, 0xFF, 0xE0, 0x47); jr(0x18, "main")
    code = a.resolve()

    rom = bytearray(0x8000)
    rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])
    rom[0x104:0x134] = NINTENDO_LOGO_GB
    rom[0x134:0x13A] = b"PTTEST"
    rom[0x14A] = 1
    rom[0x150:0x150 + len(code)] = code
    checksum = 0
    for b in rom[0x134:0x14D]:
        checksum = (checksum - b - 1) & 0xFF
    rom[0x14D] = checksum
    total = sum(rom) - rom[0x14E] - rom[0x14F]
    rom[0x14E:0x150] = struct.pack(">H", total & 0xFFFF)
    return bytes(rom)


# --------------------------------------------------------------- ARM (GBA/DS)
class ArmAsm(Asm):
    """Quelques instructions ARM, avec réserve de constantes (« ldr rX, =valeur »)."""

    def __init__(self, origin):
        super().__init__(origin)
        self.pool = []

    def word(self, value): self.code += struct.pack("<I", value)

    def ldr_const(self, rd, value, cond=0xE):
        name = f"pool{len(self.pool)}"
        self.pool.append((name, value))
        pos = len(self.code)
        self.word(0)
        def compute(target, here, rd=rd, cond=cond):
            offset = target - (here + 8)
            return struct.pack("<I", (cond << 28) | 0x059F0000 | (rd << 12) | offset)
        self.fixups.append((pos, 4, name, compute))

    def branch(self, name, cond=0xE):
        def compute(target, here, cond=cond):
            return struct.pack("<I", (cond << 28) | 0x0A000000 | (((target - (here + 8)) >> 2) & 0xFFFFFF))
        self.ref(4, name, compute)

    def flush_pool(self):
        for name, value in self.pool:
            self.label(name)
            self.word(value)


def arm_fill_program(a, *, width, height, vram, setup):
    setup(a)
    a.ldr_const(6, 0x04000130)                 # KEYINPUT
    a.label("main")
    a.word(0xE1D650B0)                         # ldrh r5, [r6]
    a.word(0xE3150001)                         # tst r5, #1   (A appuyé → bit à 0)
    a.ldr_const(3, 0x001F, cond=0x0)           # ldreq r3, =rouge
    a.ldr_const(3, 0x7C00, cond=0x1)           # ldrne r3, =bleu
    a.ldr_const(2, vram)
    a.ldr_const(4, width * height)
    a.label("fill")
    a.word(0xE0C230B2)                         # strh r3, [r2], #2
    a.word(0xE2544001)                         # subs r4, r4, #1
    a.branch("fill", cond=0x1)                 # bne fill
    a.branch("main")
    a.flush_pool()
    return a.resolve()


def gba():
    def setup(a):
        a.word(0xE3A00301)                     # mov r0, #0x04000000
        a.ldr_const(1, 0x0403)                 # mode 3 + BG2
        a.word(0xE1C010B0)                     # strh r1, [r0]
    code = arm_fill_program(ArmAsm(0x080000C0), width=240, height=160, vram=0x06000000, setup=setup)
    rom = bytearray(0xC0)
    rom[0:4] = struct.pack("<I", 0xEA00002E)   # b 0xC0
    rom[0xA0:0xAC] = b"PTTEST".ljust(12, b"\0")
    rom[0xAC:0xB0] = b"PTTE"
    rom[0xB0:0xB2] = b"00"
    rom[0xB2] = 0x96
    rom[0xBD] = (-(sum(rom[0xA0:0xBD]) + 0x19)) & 0xFF
    return bytes(rom) + code


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def nds():
    def setup(a):
        a.ldr_const(0, 0x04000304); a.ldr_const(1, 0x8003)
        a.word(0xE1C010B0)                     # strh r1, [r0]  POWCNT1
        a.ldr_const(0, 0x04000240)
        a.word(0xE3A01080)                     # mov r1, #0x80
        a.word(0xE5C01000)                     # strb r1, [r0]  VRAMCNT_A = LCDC
        a.word(0xE3A00301)                     # mov r0, #0x04000000
        a.ldr_const(1, 0x00020000)             # DISPCNT : mode « affichage VRAM »
        a.word(0xE5801000)                     # str r1, [r0]
    arm9 = arm_fill_program(ArmAsm(0x02000000), width=256, height=192, vram=0x06800000, setup=setup)
    arm7 = struct.pack("<I", 0xEAFFFFFE)       # b .
    arm9 += bytes((-len(arm9)) % 0x200)
    arm7_offset = 0x200 + len(arm9)
    header = bytearray(0x200)
    header[0:12] = b"PTTEST".ljust(12, b"\0")
    header[12:16] = b"PTTE"
    header[16:18] = b"00"
    struct.pack_into("<IIII", header, 0x20, 0x200, 0x02000000, 0x02000000, len(arm9))
    struct.pack_into("<IIII", header, 0x30, arm7_offset, 0x02380000, 0x02380000, len(arm7))
    struct.pack_into("<I", header, 0x80, arm7_offset + len(arm7))
    struct.pack_into("<I", header, 0x84, 0x4000)
    struct.pack_into("<H", header, 0x15C, 0xCF56)
    struct.pack_into("<H", header, 0x15E, crc16(header[:0x15E]))
    rom = bytes(header) + arm9 + arm7
    return rom + bytes((-len(rom)) % 0x20000)


# --------------------------------------------------------------- PS1 (MIPS)
def ps1_exe():
    words = []
    lui = lambda rt, imm: words.append(0x3C000000 | (rt << 16) | imm)
    ori = lambda rt, rs, imm: words.append(0x34000000 | (rs << 21) | (rt << 16) | imm)
    sw = lambda rt, off, base: words.append(0xAC000000 | (base << 21) | (rt << 16) | (off & 0xFFFF))
    T0, T1 = 8, 9

    def gp1(value):
        lui(T1, value >> 16)
        if value & 0xFFFF: ori(T1, T1, value & 0xFFFF)
        sw(T1, 0x1814, T0)

    def gp0(value):
        lui(T1, value >> 16)
        if value & 0xFFFF: ori(T1, T1, value & 0xFFFF)
        sw(T1, 0x1810, T0)

    lui(T0, 0x1F80)
    sw(0, 0x1814, T0)                          # GP1(00) : remise à zéro
    gp1(0x03000000)                            # affichage activé
    gp1(0x08000001)                            # 320×240, NTSC
    gp1(0x06C60260)
    gp1(0x07040010)
    gp1(0x05000000)
    gp0(0xE1000400); gp0(0xE3000000); gp0(0xE403BD3F); gp0(0xE5000000)
    main = len(words)
    gp0(0x02FF0000)                            # rectangle plein, bleu
    sw(0, 0x1810, T0)                          # en (0,0)
    gp0(0x00F00140)                            # 320×240
    # Petite pause (~1/60 s) pour ressembler à un vrai jeu, qui ne redessine qu'une fois par image.
    lui(10, 0x0004)                            # t2 = 0x40000
    delay = len(words)
    words.append(0x254AFFFF)                   # addiu t2, t2, -1
    words.append(0x1540FFFE)                   # bne t2, zero, delay
    words.append(0)                            # nop
    words.append(0x10000000 | ((main - (len(words) + 1)) & 0xFFFF))   # b main
    words.append(0)                            # nop (délai de branchement)
    code = b"".join(struct.pack("<I", w) for w in words)
    code += bytes((-len(code)) % 0x800)

    header = bytearray(0x800)
    header[0:8] = b"PS-X EXE"
    struct.pack_into("<IIII", header, 0x10, 0x80010000, 0, 0x80010000, len(code))
    struct.pack_into("<I", header, 0x30, 0x801FFFF0)
    header[0x4C:0x4C + 46] = b"Sony Computer Entertainment Inc. for Europe area"[:46]
    return bytes(header) + code


def snes():
    a = Asm(0x8000)
    rel8 = lambda target, here: struct.pack("<b", target - (here + 1))

    def op_abs(opcode, address): a.emit(opcode, *struct.pack("<H", address))
    def br(opcode, name): a.emit(opcode); a.ref(1, name, rel8)

    def set_color(low, high):
        a.label(f"vb{low}"); op_abs(0xAD, 0x4212); br(0x10, f"vb{low}")    # attendre la VBlank
        op_abs(0x9C, 0x2121)
        a.emit(0xA9, low); op_abs(0x8D, 0x2122)
        a.emit(0xA9, high); op_abs(0x8D, 0x2122)

    a.label("reset")
    a.emit(0x78, 0x18, 0xFB)                   # SEI ; CLC ; XCE (mode natif)
    a.emit(0xA9, 0x8F); op_abs(0x8D, 0x2100)
    op_abs(0x9C, 0x2121)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2122)
    a.emit(0xA9, 0x7C); op_abs(0x8D, 0x2122)
    a.emit(0xA9, 0x0F); op_abs(0x8D, 0x2100)
    a.emit(0xA9, 0x01); op_abs(0x8D, 0x4200)   # lecture auto des manettes
    a.label("main")
    op_abs(0xAD, 0x4218); a.emit(0x29, 0x80)   # bouton A
    br(0xF0, "notA")
    set_color(0x1F, 0x00)                      # rouge
    br(0x80, "main")
    a.label("notA")
    set_color(0x00, 0x7C)                      # bleu
    br(0x80, "main")
    a.label("rti"); a.emit(0x40)
    code = a.resolve()

    rom = bytearray(0x8000)
    rom[:len(code)] = code
    rom[0x7FC0:0x7FD5] = b"PLAYTENDO TEST".ljust(21, b" ")
    rom[0x7FD5] = 0x20
    rom[0x7FD7] = 0x05
    rom[0x7FD9] = 0x01
    rti = a.labels["rti"]
    for vector in (0x7FE4, 0x7FE6, 0x7FE8, 0x7FEA, 0x7FEE, 0x7FF4, 0x7FFA, 0x7FFE):
        struct.pack_into("<H", rom, vector, rti)
    struct.pack_into("<H", rom, 0x7FFC, a.labels["reset"])
    struct.pack_into("<HH", rom, 0x7FDC, 0xFFFF, 0x0000)
    checksum = sum(rom) & 0xFFFF
    struct.pack_into("<HH", rom, 0x7FDC, checksum ^ 0xFFFF, checksum)
    return bytes(rom)


for name, data in [("test.nes", nes()), ("test.sfc", snes()), ("test.gb", gameboy()),
                   ("test.gba", gba()), ("test.nds", nds()), ("test.exe", ps1_exe())]:
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)
    print(f"{name:10s} {len(data):7d} octets")

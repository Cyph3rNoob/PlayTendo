#!/usr/bin/env python3
"""Fabrique des mini-jeux de test (fait maison, aucun téléchargement).

Chaque jeu remplit l'écran d'une couleur qui dépend du bouton appuyé, ce qui permet
de vérifier un par un que chaque bouton arrive bien jusqu'au jeu :

  aucun = bleu      A = rouge         B = vert          X = jaune         Y = cyan
  L/L1 = orange     R/R1 = violet     L2 = rouge foncé  R2 = violet foncé
  Start = blanc     Select = gris     Haut = rose       Bas = marron
  Gauche = vert foncé   Droite = bleu clair   écran tactile (DS) = noir

N64 : Z = rouge foncé, C haut/bas/gauche/droite = jaune/cyan/gris/violet foncé.
N64 et PSP, stick : haut = olive, bas = bleu marine, gauche = turquoise, droite = saumon.
"""
import os
import struct
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "roms"
os.makedirs(OUT, exist_ok=True)

COLORS = {
    "bleu": (0, 0, 255), "rouge": (255, 0, 0), "vert": (0, 255, 0), "jaune": (255, 255, 0),
    "cyan": (0, 255, 255), "orange": (255, 128, 0), "violet": (128, 0, 128),
    "rouge foncé": (128, 0, 0), "violet foncé": (64, 0, 64), "blanc": (255, 255, 255),
    "gris": (128, 128, 128), "rose": (255, 128, 192), "marron": (128, 64, 32),
    "vert foncé": (0, 96, 0), "bleu clair": (96, 160, 255), "noir": (0, 0, 0),
    "olive": (128, 128, 0), "bleu marine": (0, 0, 128), "turquoise": (0, 128, 128),
    "saumon": (255, 160, 128),
}


def bgr555(name):
    r, g, b = COLORS[name]
    return (b >> 3) << 10 | (g >> 3) << 5 | (r >> 3)


def bgr24(name):
    r, g, b = COLORS[name]
    return b << 16 | g << 8 | r


class Asm:
    """Assembleur minimal : octets bruts + étiquettes + corrections en 2e passe."""

    def __init__(self, origin):
        self.origin = origin
        self.code = bytearray()
        self.labels = {}
        self.fixups = []

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

    def word(self, value):
        self.code += struct.pack("<I", value)

    def half(self, value):
        self.code += struct.pack("<H", value)

    def resolve(self):
        for pos, size, name, compute in self.fixups:
            self.code[pos:pos + size] = compute(self.labels[name], self.origin + pos)
        return bytes(self.code)


ABS16 = lambda target, here: struct.pack("<H", target & 0xFFFF)
ABS32 = lambda target, here: struct.pack("<I", target)
REL8 = lambda target, here: struct.pack("<b", target - (here + 1))


# ---------------------------------------------------------------- NES (6502)
def nes():
    a = Asm(0xC000)

    def op_abs(opcode, address): a.emit(opcode, *struct.pack("<H", address))
    def branch(opcode, name): a.emit(opcode); a.ref(1, name, REL8)

    a.label("reset")
    a.emit(0x78, 0xD8)                         # SEI ; CLD
    a.emit(0xA2, 0x40); op_abs(0x8E, 0x4017)
    a.emit(0xA2, 0xFF, 0x9A, 0xE8)             # LDX #$FF ; TXS ; INX
    op_abs(0x8E, 0x2000); op_abs(0x8E, 0x2001); op_abs(0x8E, 0x4010)
    for n in ("vb1", "vb2"):
        a.label(n); op_abs(0x2C, 0x2002); branch(0x10, n)
    a.emit(0xA9, 0x3F); op_abs(0x8D, 0x2006)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2006)
    a.emit(0xA9, 0x12); op_abs(0x8D, 0x2007)   # fond bleu
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2005); op_abs(0x8D, 0x2005)
    a.emit(0xA9, 0x80); op_abs(0x8D, 0x2000)
    a.emit(0xA9, 0x0A); op_abs(0x8D, 0x2001)
    a.label("loop"); a.emit(0x4C); a.ref(2, "loop", ABS16)

    a.label("nmi")
    a.emit(0x48, 0x8A, 0x48, 0x98, 0x48)       # sauvegarde A, X, Y
    a.emit(0xA9, 0x01); op_abs(0x8D, 0x4016)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x4016)
    a.emit(0xA2, 0x08)                         # 8 boutons : A B Select Start Haut Bas Gauche Droite
    a.label("read"); op_abs(0xAD, 0x4016); a.emit(0x4A, 0x26, 0x00, 0xCA); branch(0xD0, "read")
    a.emit(0xA5, 0x00, 0xA0, 0x00)             # LDA $00 ; LDY #0
    a.label("check"); a.emit(0x0A); branch(0xB0, "found"); a.emit(0xC8, 0xC0, 0x08); branch(0xD0, "check")
    a.emit(0xA2, 0x12); a.emit(0x4C); a.ref(2, "write", ABS16)   # aucun bouton : bleu
    a.label("found"); a.emit(0xBE); a.ref(2, "colors", ABS16)    # LDX colors,Y
    a.label("write")
    op_abs(0xAD, 0x2002)
    a.emit(0xA9, 0x3F); op_abs(0x8D, 0x2006)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2006)
    op_abs(0x8E, 0x2007)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2005); op_abs(0x8D, 0x2005)
    a.emit(0xA9, 0x80); op_abs(0x8D, 0x2000)
    a.emit(0x68, 0xA8, 0x68, 0xAA, 0x68, 0x40) # restauration ; RTI
    a.label("irq"); a.emit(0x40)
    # Couleurs de la palette NES : rouge, vert, gris, blanc, rose, marron, vert foncé, bleu clair.
    a.label("colors"); a.emit(0x16, 0x2A, 0x00, 0x30, 0x25, 0x17, 0x0A, 0x21)
    code = a.resolve()

    prg = bytearray(0x4000)
    prg[:len(code)] = code
    prg[0x3FFA:0x4000] = struct.pack("<HHH", a.labels["nmi"], a.labels["reset"], a.labels["irq"])
    return b"NES\x1a" + bytes([1, 1, 0, 0]) + bytes(8) + bytes(prg) + bytes(0x2000)


# ------------------------------------------------------------ SNES (65816)
def snes():
    a = Asm(0x8000)

    def op_abs(opcode, address): a.emit(opcode, *struct.pack("<H", address))
    def br(opcode, name): a.emit(opcode); a.ref(1, name, REL8)

    a.label("reset")
    a.emit(0x78, 0x18, 0xFB)                   # SEI ; CLC ; XCE
    a.emit(0xA9, 0x8F); op_abs(0x8D, 0x2100)
    op_abs(0x9C, 0x2121)
    a.emit(0xA9, 0x00); op_abs(0x8D, 0x2122)
    a.emit(0xA9, 0x7C); op_abs(0x8D, 0x2122)
    a.emit(0xA9, 0x0F); op_abs(0x8D, 0x2100)
    a.emit(0xA9, 0x01); op_abs(0x8D, 0x4200)   # lecture auto des manettes
    a.label("main")
    a.emit(0xC2, 0x20)                         # REP #$20 (A sur 16 bits)
    op_abs(0xAD, 0x4218)                       # bits 15→4 : B Y Select Start Haut Bas Gauche Droite A X L R
    a.emit(0xA2, 0x00)
    a.label("find"); a.emit(0x0A); br(0xB0, "found"); a.emit(0xE8, 0xE8, 0xE0, 0x18); br(0xD0, "find")
    a.emit(0xA9, *struct.pack("<H", bgr555("bleu"))); br(0x80, "store")
    a.label("found"); a.emit(0xBD); a.ref(2, "colors", ABS16)   # LDA colors,X
    a.label("store")
    a.emit(0x85, 0x00, 0xE2, 0x20)             # STA $00 ; SEP #$20
    a.label("vbl"); op_abs(0xAD, 0x4212); br(0x10, "vbl")
    op_abs(0x9C, 0x2121)
    a.emit(0xA5, 0x00); op_abs(0x8D, 0x2122)
    a.emit(0xA5, 0x01); op_abs(0x8D, 0x2122)
    br(0x80, "main")
    a.label("rti"); a.emit(0x40)
    a.label("colors")
    for name in ["vert", "cyan", "gris", "blanc", "rose", "marron", "vert foncé", "bleu clair",
                 "rouge", "jaune", "orange", "violet"]:
        a.half(bgr555(name))
    code = a.resolve()

    rom = bytearray(0x8000)
    rom[:len(code)] = code
    rom[0x7FC0:0x7FD5] = b"PLAYTENDO TEST".ljust(21, b" ")
    rom[0x7FD5] = 0x20
    rom[0x7FD7] = 0x05
    rom[0x7FD9] = 0x01
    for vector in (0x7FE4, 0x7FE6, 0x7FE8, 0x7FEA, 0x7FEE, 0x7FF4, 0x7FFA, 0x7FFE):
        struct.pack_into("<H", rom, vector, a.labels["rti"])
    struct.pack_into("<H", rom, 0x7FFC, a.labels["reset"])
    struct.pack_into("<HH", rom, 0x7FDC, 0xFFFF, 0x0000)
    checksum = sum(rom) & 0xFFFF
    struct.pack_into("<HH", rom, 0x7FDC, checksum ^ 0xFFFF, checksum)
    return bytes(rom)


# ----------------------------------------------- Game Boy Color (SM83)
NINTENDO_LOGO_GB = bytes.fromhex(
    "CEED6666CC0D000B03730083000C000D0008111F8889000EDCCC6EE6DDDDD999BBBB67636E0EECCCDDDC999FBBB9333E")


def gameboy():
    a = Asm(0x150)

    def jr(opcode, name): a.emit(opcode); a.ref(1, name, REL8)

    def clear(address, length):
        a.emit(0x21, *struct.pack("<H", address), 0x01, *struct.pack("<H", length))
        name = f"clear{address:x}"
        a.label(name); a.emit(0xAF, 0x22, 0x0B, 0x78, 0xB1); jr(0x20, name)

    a.emit(0xF3, 0x31, 0xFE, 0xFF)             # DI ; LD SP,$FFFE
    a.label("wait"); a.emit(0xF0, 0x44, 0xFE, 144); jr(0x38, "wait")
    a.emit(0xAF, 0xE0, 0x40)                   # écran éteint
    clear(0x8000, 0x2000)
    a.emit(0x3E, 0x01, 0xE0, 0x4F)             # banque VRAM 1 (attributs couleur)
    clear(0x9800, 0x0400)
    a.emit(0xAF, 0xE0, 0x4F)
    a.emit(0x3E, 0x91, 0xE0, 0x40)             # écran allumé
    a.label("main")
    a.emit(0x3E, 0x20, 0xE0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0x2F, 0xE6, 0x0F, 0xCB, 0x37, 0x47)  # croix → B
    a.emit(0x3E, 0x10, 0xE0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0x2F, 0xE6, 0x0F, 0xB0)              # A B Select Start
    a.emit(0x21); a.ref(2, "colors", ABS16)
    a.emit(0x0E, 0x08)
    a.label("find"); a.emit(0xCB, 0x3F); jr(0x38, "found"); a.emit(0x23, 0x23, 0x0D); jr(0x20, "find")
    a.emit(0x21); a.ref(2, "blue", ABS16)
    a.label("found")
    a.label("vbl"); a.emit(0xF0, 0x44, 0xFE, 144); jr(0x38, "vbl")
    a.emit(0x3E, 0x80, 0xE0, 0x68)             # BCPS : couleur 0, auto-incrément
    a.emit(0x2A, 0xE0, 0x69, 0x7E, 0xE0, 0x69) # BCPD ← couleur
    jr(0x18, "main")
    a.label("colors")
    for name in ["rouge", "vert", "gris", "blanc", "bleu clair", "vert foncé", "rose", "marron"]:
        a.half(bgr555(name))
    a.label("blue"); a.half(bgr555("bleu"))
    code = a.resolve()

    rom = bytearray(0x8000)
    rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])
    rom[0x104:0x134] = NINTENDO_LOGO_GB
    rom[0x134:0x13A] = b"PTTEST"
    rom[0x143] = 0x80                          # compatible Game Boy Color
    rom[0x14A] = 1
    rom[0x150:0x150 + len(code)] = code
    checksum = 0
    for b in rom[0x134:0x14D]:
        checksum = (checksum - b - 1) & 0xFF
    rom[0x14D] = checksum
    rom[0x14E:0x150] = struct.pack(">H", (sum(rom) - rom[0x14E] - rom[0x14F]) & 0xFFFF)
    return bytes(rom)


# --------------------------------------------------------------- ARM (GBA/DS)
class ArmAsm(Asm):
    """Quelques instructions ARM, avec réserve de constantes (« ldr rX, =valeur »)."""

    def __init__(self, origin):
        super().__init__(origin)
        self.pool = []

    def ldr(self, rd, value, cond=0xE):
        name = f"pool{len(self.pool)}"
        self.pool.append((name, value))
        def compute(target, here, rd=rd, cond=cond):
            return struct.pack("<I", (cond << 28) | 0x059F0000 | (rd << 12) | (target - (here + 8)))
        self.ref(4, name, compute)

    def branch(self, name, cond=0xE):
        def compute(target, here, cond=cond):
            return struct.pack("<I", (cond << 28) | 0x0A000000 | (((target - (here + 8)) >> 2) & 0xFFFFFF))
        self.ref(4, name, compute)

    def flush_pool(self):
        for name, value in self.pool:
            self.label(name)
            if isinstance(value, str):
                self.ref(4, value, ABS32)      # adresse d'une étiquette
            else:
                self.word(value)


def arm_color_program(a, *, width, height, vram, buttons, colors, setup, extra_keys=None):
    setup(a)
    a.ldr(6, 0x04000130)                       # KEYINPUT
    a.label("main")
    a.word(0xE1D650B0)                         # ldrh r5, [r6]
    a.word(0xE1E05005)                         # mvn r5, r5   (1 = appuyé)
    if extra_keys:
        extra_keys(a)
    a.ldr(3, bgr555("bleu"))
    a.ldr(7, "colors")
    a.word(0xE3A08000 | buttons)               # mov r8, #nombre de boutons
    a.label("find")
    a.word(0xE3150001)                         # tst r5, #1
    a.word(0x11D730B0)                         # ldrhne r3, [r7]
    a.branch("fill", cond=0x1)                 # bne fill
    a.word(0xE1A050A5)                         # mov r5, r5, lsr #1
    a.word(0xE2877002)                         # add r7, r7, #2
    a.word(0xE2588001)                         # subs r8, r8, #1
    a.branch("find", cond=0x1)
    a.label("fill")
    a.ldr(2, vram)
    a.ldr(4, width * height)
    a.label("fillloop")
    a.word(0xE0C230B2)                         # strh r3, [r2], #2
    a.word(0xE2544001)                         # subs r4, r4, #1
    a.branch("fillloop", cond=0x1)
    a.branch("main")
    a.flush_pool()
    a.label("colors")
    for name in colors:
        a.half(bgr555(name))
    a.code += bytes((-len(a.code)) % 4)
    return a.resolve()


GBA_COLORS = ["rouge", "vert", "gris", "blanc", "bleu clair", "vert foncé", "rose", "marron", "violet", "orange"]


def gba():
    def setup(a):
        a.word(0xE3A00301)                     # mov r0, #0x04000000
        a.ldr(1, 0x0403)                       # mode 3 + BG2
        a.word(0xE1C010B0)                     # strh r1, [r0]
    code = arm_color_program(ArmAsm(0x080000C0), width=240, height=160, vram=0x06000000,
                             buttons=10, colors=GBA_COLORS, setup=setup)
    rom = bytearray(0xC0)
    rom[0:4] = struct.pack("<I", 0xEA00002E)   # b 0xC0
    rom[0xA0:0xAC] = b"PTTEST".ljust(12, b"\0")
    rom[0xAC:0xB0] = b"PTTE"
    rom[0xB0:0xB2] = b"00"
    rom[0xB2] = 0x96
    rom[0xBD] = (-(sum(rom[0xA0:0xBD]) + 0x19)) & 0xFF
    rom = bytes(rom) + code
    return rom + bytes((-len(rom)) % 0x8000)


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


SHARED_KEYS = 0x023FF000                       # mémoire partagée : l'ARM7 y recopie X, Y et le stylet


def nds():
    def setup(a):
        # Cache de données désactivé : sinon l'ARM9 relit une vieille copie de la mémoire partagée.
        a.word(0xEE110F10)                     # mrc p15, 0, r0, c1, c0, 0
        a.word(0xE3C00004)                     # bic r0, r0, #4
        a.word(0xEE010F10)                     # mcr p15, 0, r0, c1, c0, 0
        a.ldr(0, 0x04000304); a.ldr(1, 0x8003)
        a.word(0xE1C010B0)                     # POWCNT1
        a.ldr(0, 0x04000240)
        a.word(0xE3A01080)                     # mov r1, #0x80
        a.word(0xE5C01000)                     # VRAMCNT_A = LCDC
        a.word(0xE3A00301)                     # mov r0, #0x04000000
        a.ldr(1, 0x00020000)                   # DISPCNT : mode « affichage VRAM »
        a.word(0xE5801000)

    def extra_keys(a):
        a.word(0xE3C55CFC)                     # bic r5, r5, #0xFC00 (bits inutilisés de KEYINPUT)
        a.ldr(9, SHARED_KEYS)
        a.word(0xE1D9A0B0)                     # ldrh r10, [r9]  (EXTKEYIN recopié par l'ARM7)
        a.word(0xE1E0A00A)                     # mvn r10, r10
        a.word(0xE20AB003)                     # and r11, r10, #3     (X, Y)
        a.word(0xE185550B)                     # orr r5, r5, r11, lsl #10
        a.word(0xE1A0A32A)                     # mov r10, r10, lsr #6 (stylet)
        a.word(0xE20AA001)                     # and r10, r10, #1
        a.word(0xE185560A)                     # orr r5, r5, r10, lsl #12

    arm9 = arm_color_program(ArmAsm(0x02000000), width=256, height=192, vram=0x06800000, buttons=13,
                             colors=GBA_COLORS + ["jaune", "cyan", "noir"], setup=setup, extra_keys=extra_keys)
    arm7asm = ArmAsm(0x02380000)
    arm7asm.ldr(0, 0x04000136)                 # EXTKEYIN
    arm7asm.ldr(2, SHARED_KEYS)
    arm7asm.label("loop")
    arm7asm.word(0xE1D010B0)                   # ldrh r1, [r0]
    arm7asm.word(0xE1C210B0)                   # strh r1, [r2]
    arm7asm.branch("loop")
    arm7asm.flush_pool()
    arm7 = arm7asm.resolve()

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
class MipsAsm:
    ZERO, A0, A1, A2, A3, T0, T1, T2, T3, T4, T5, T6, T7, RA = 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 31

    def __init__(self, origin, endian="<"):
        self.origin = origin
        self.endian = endian                   # "<" PS1/PSP, ">" N64
        self.words = []
        self.labels = {}
        self.fixups = []

    def label(self, name): self.labels[name] = self.origin + 4 * len(self.words)
    def op(self, word): self.words.append(word & 0xFFFFFFFF)
    def nop(self): self.op(0)
    def lui(self, rt, imm): self.op(0x3C000000 | rt << 16 | imm)
    def ori(self, rt, rs, imm): self.op(0x34000000 | rs << 21 | rt << 16 | imm)
    def andi(self, rt, rs, imm): self.op(0x30000000 | rs << 21 | rt << 16 | imm)
    def addiu(self, rt, rs, imm): self.op(0x24000000 | rs << 21 | rt << 16 | (imm & 0xFFFF))
    def sw(self, rt, off, base): self.op(0xAC000000 | base << 21 | rt << 16 | (off & 0xFFFF))
    def sh(self, rt, off, base): self.op(0xA4000000 | base << 21 | rt << 16 | (off & 0xFFFF))
    def sb(self, rt, off, base): self.op(0xA0000000 | base << 21 | rt << 16 | (off & 0xFFFF))
    def lw(self, rt, off, base): self.op(0x8C000000 | base << 21 | rt << 16 | (off & 0xFFFF))
    def lhu(self, rt, off, base): self.op(0x94000000 | base << 21 | rt << 16 | (off & 0xFFFF))
    def lbu(self, rt, off, base): self.op(0x90000000 | base << 21 | rt << 16 | (off & 0xFFFF))
    def srl(self, rd, rt, sa): self.op(0x00000002 | rt << 16 | rd << 11 | sa << 6)
    def sll(self, rd, rt, sa): self.op(0x00000000 | rt << 16 | rd << 11 | sa << 6)
    def or_(self, rd, rs, rt): self.op(0x00000025 | rs << 21 | rt << 16 | rd << 11)
    def nor(self, rd, rs, rt): self.op(0x00000027 | rs << 21 | rt << 16 | rd << 11)
    def and_(self, rd, rs, rt): self.op(0x00000024 | rs << 21 | rt << 16 | rd << 11)
    def sra(self, rd, rt, sa): self.op(0x00000003 | rt << 16 | rd << 11 | sa << 6)
    def slti(self, rt, rs, imm): self.op(0x28000000 | rs << 21 | rt << 16 | (imm & 0xFFFF))
    def jr(self, rs): self.op(0x00000008 | rs << 21)

    def load32(self, rt, value):
        self.lui(rt, value >> 16)
        if value & 0xFFFF: self.ori(rt, rt, value & 0xFFFF)

    def jal(self, name):
        self.fixups.append((len(self.words), name, "jal", 0, 0))
        self.op(0)
        self.nop()                             # délai de branchement

    def addr(self, name):
        """Mot de données contenant l'adresse d'une étiquette."""
        self.fixups.append((len(self.words), name, "addr", 0, 0))
        self.op(0)

    def data(self, raw):
        """Octets bruts (complétés à un multiple de 4)."""
        raw = raw + bytes((-len(raw)) % 4)
        for i in range(0, len(raw), 4):
            self.op(struct.unpack_from("<I", raw, i)[0])

    def branch(self, opcode, rs, rt, name):
        self.fixups.append((len(self.words), name, opcode, rs, rt))
        self.op(0)
        self.nop()                             # délai de branchement

    def la(self, rt, name):
        self.fixups.append((len(self.words), name, "la", rt, 0))
        self.op(0)
        self.op(0)

    def resolve(self):
        for index, name, opcode, rs, rt in self.fixups:
            target = self.labels[name]
            if opcode == "la":
                self.words[index] = 0x3C000000 | rs << 16 | (target >> 16)
                self.words[index + 1] = 0x34000000 | rs << 21 | rs << 16 | (target & 0xFFFF)
            elif opcode == "jal":
                self.words[index] = 0x0C000000 | (target >> 2) & 0x03FFFFFF
            elif opcode == "addr":
                self.words[index] = target
            else:
                offset = (target - (self.origin + 4 * index + 4)) // 4
                self.words[index] = opcode << 26 | rs << 21 | rt << 16 | (offset & 0xFFFF)
        return b"".join(struct.pack(self.endian + "I", w) for w in self.words)


def ps1_exe():
    m = MipsAsm(0x80010000)
    T0, T1, T2, T3, T4, T5, T6, T7 = m.T0, m.T1, m.T2, m.T3, m.T4, m.T5, m.T6, m.T7

    def load32(reg, value):
        m.lui(reg, value >> 16)
        if value & 0xFFFF: m.ori(reg, reg, value & 0xFFFF)

    def gp1(value): load32(T1, value); m.sw(T1, 0x1814, T0)
    def gp0(value): load32(T1, value); m.sw(T1, 0x1810, T0)

    def exchange(byte, into=None):
        """Envoie un octet à la manette et lit sa réponse (port série SIO0)."""
        m.ori(T1, 0, byte)
        m.sb(T1, 0x1040, T0)
        name = f"rx{len(m.words)}"
        m.label(name)
        m.lhu(T2, 0x1044, T0); m.nop()
        m.andi(T2, T2, 0x0002)
        m.branch(4, T2, 0, name)               # beq : attendre une réponse
        m.lbu(into if into else T2, 0x1040, T0); m.nop()

    m.lui(T0, 0x1F80)
    m.sw(0, 0x1814, T0)
    gp1(0x03000000); gp1(0x08000001); gp1(0x06C60260); gp1(0x07040010); gp1(0x05000000)
    gp0(0xE1000400); gp0(0xE3000000); gp0(0xE403BD3F); gp0(0xE5000000)

    m.label("main")
    m.ori(T1, 0, 0x000D); m.sh(T1, 0x1048, T0)     # JOY_MODE
    m.ori(T1, 0, 0x0088); m.sh(T1, 0x104E, T0)     # JOY_BAUD
    m.ori(T1, 0, 0x0003); m.sh(T1, 0x104A, T0)     # JOY_CTRL : manette 1 sélectionnée
    exchange(0x01); exchange(0x42); exchange(0x00)
    exchange(0x00, into=T3); exchange(0x00, into=T4)
    m.sh(0, 0x104A, T0)
    m.sll(T4, T4, 8); m.or_(T3, T3, T4); m.nor(T3, T3, 0)    # 16 boutons, 1 = appuyé
    m.la(T4, "colors")
    m.ori(T5, 0, 16)
    load32(T6, bgr24("bleu"))
    m.label("find")
    m.andi(T2, T3, 1)
    m.branch(5, T2, 0, "found")                # bne
    m.srl(T3, T3, 1)
    m.addiu(T4, T4, 4)
    m.addiu(T5, T5, -1)
    m.branch(5, T5, 0, "find")
    m.branch(4, 0, 0, "fill")                  # b fill
    m.label("found")
    m.lw(T6, 0, T4); m.nop()
    m.label("fill")
    m.lui(T1, 0x0200); m.or_(T1, T1, T6); m.sw(T1, 0x1810, T0)   # rectangle plein
    m.sw(0, 0x1810, T0)
    gp0(0x00F00140)
    m.lui(T7, 0x0004)                          # petite pause (~1/60 s)
    m.label("delay"); m.addiu(T7, T7, -1); m.branch(5, T7, 0, "delay")
    m.branch(4, 0, 0, "main")
    m.label("colors")
    for name in ["gris", "noir", "noir", "blanc", "rose", "bleu clair", "marron", "vert foncé",
                 "rouge foncé", "violet foncé", "orange", "violet", "jaune", "rouge", "vert", "cyan"]:
        m.op(bgr24(name))
    code = m.resolve()
    code += bytes((-len(code)) % 0x800)

    header = bytearray(0x800)
    header[0:8] = b"PS-X EXE"
    struct.pack_into("<IIII", header, 0x10, 0x80010000, 0, 0x80010000, len(code))
    struct.pack_into("<I", header, 0x30, 0x801FFFF0)
    return bytes(header) + code


# --------------------------------------------------------------- N64 (MIPS, gros-boutiste)
def rgba5551_pair(name):
    r, g, b = COLORS[name]
    c = (r >> 3) << 11 | (g >> 3) << 6 | (b >> 3) << 1 | 1
    return c << 16 | c                         # deux pixels 16 bits


# Réponse de la manette (bits 15 → 0) : A, B, Z, Start, croix H/B/G/D, 2 bits inutilisés, L, R, C H/B/G/D.
N64_COLORS = ["rouge", "vert", "rouge foncé", "blanc", "rose", "marron", "vert foncé", "bleu clair",
              "bleu", "bleu", "orange", "violet", "jaune", "cyan", "gris", "violet foncé"]


def stick_tables(m, color):
    for label, name in [("stick_haut", "olive"), ("stick_bas", "bleu marine"), ("stick_gauche", "turquoise"),
                        ("stick_droite", "saumon"), ("repos", "bleu")]:
        m.label(label)
        m.op(color(name))


def n64():
    """Cartouche N64 : le démarrage de la console copie le début de la cartouche dans la mémoire
    du coprocesseur (0xA4000040) et l'exécute ; notre programme tient entièrement là-dedans.
    Il lit la manette 1 par le PIF et remplit l'écran avec le processeur graphique (RDP)."""
    m = MipsAsm(0xA4000040, endian=">")
    T0, T1, T2, T3, T4, T5, T6, T7 = m.T0, m.T1, m.T2, m.T3, m.T4, m.T5, m.T6, m.T7
    FB = 0x00200000                            # image 320×240 en 16 bits
    DATA = 0x00100000                          # commande manette, réponse, liste RDP

    def store(base, offset, value):
        m.load32(T1, value)
        m.sw(T1, offset, base)

    m.lui(T0, 0xA430); store(T0, 0x0C, 0x0555)          # interruptions masquées
    # Affichage (VI) : mode NTSC 320×240 standard des jeux (« LAN1 » de la bibliothèque Nintendo),
    # image commençant une ligne après le début du tampon, comme dans les vrais jeux.
    m.lui(T0, 0xA440)
    for i, value in enumerate([0x311E, FB + 640, 320, 2, 0, 0x03E52239, 0x20D, 0xC15, 0x0C150C15,
                               0x006C02EC, 0x002501FF, 0x000E0204, 0x200, 0x400]):
        store(T0, 4 * i, value)

    m.lui(T0, 0xA010)                                    # 0xA0100000 = DATA, sans cache
    for i, value in enumerate([0xFF010401, 0xFFFFFFFF, 0xFE000000] + [0] * 12 + [1]):
        store(T0, 4 * i, value)                          # « lire la manette 1 »
    rdp = [0xFF10013F, FB,                               # image de destination : RGBA 16 bits, 320 de large
           0xED000000, 0x005003C0,                       # zone de dessin 320×240
           0xEF300000, 0,                                # mode remplissage
           0xF7000000, 0,                                # couleur (changée à chaque image)
           0xF64FC3BC, 0,                                # rectangle plein (0,0)-(319,239)
           0xE9000000, 0]                                # fin
    for i, value in enumerate(rdp):
        store(T0, 0x100 + 4 * i, value)

    def wait_si():
        name = f"si{len(m.words)}"
        m.label(name)
        m.lw(T4, 0x18, T2)
        m.andi(T4, T4, 3)
        m.branch(5, T4, 0, name)

    m.label("main")
    m.lui(T2, 0xA480)                                    # liaison série (SI) vers le PIF
    store(T2, 0x00, DATA); store(T2, 0x10, 0x1FC007C0); wait_si()
    store(T2, 0x00, DATA + 0x40); store(T2, 0x04, 0x1FC007C0); wait_si()
    m.lw(T3, 0x44, T0)                                   # boutons (16 bits), stick X, stick Y
    m.srl(T4, T3, 16)
    m.ori(T5, 0, 0x8000)
    m.la(T6, "boutons")
    m.label("find")
    m.and_(T7, T4, T5)
    m.branch(5, T7, 0, "found")
    m.srl(T5, T5, 1)
    m.addiu(T6, T6, 4)
    m.branch(5, T5, 0, "find")
    m.sll(T7, T3, 16); m.sra(T7, T7, 24)                 # stick X (signé)
    m.la(T6, "stick_gauche"); m.slti(T1, T7, -40); m.branch(5, T1, 0, "found")
    m.la(T6, "stick_droite"); m.slti(T1, T7, 41); m.branch(4, T1, 0, "found")
    m.sll(T7, T3, 24); m.sra(T7, T7, 24)                 # stick Y (signé, haut = positif)
    m.la(T6, "stick_bas"); m.slti(T1, T7, -40); m.branch(5, T1, 0, "found")
    m.la(T6, "stick_haut"); m.slti(T1, T7, 41); m.branch(4, T1, 0, "found")
    m.la(T6, "repos")
    m.label("found")
    m.lw(T6, 0, T6)
    m.sw(T6, 0x11C, T0)                                  # couleur dans la liste RDP
    m.lui(T2, 0xA410)                                    # le RDP exécute la liste
    store(T2, 0x00, DATA + 0x100); store(T2, 0x04, DATA + 0x100 + 4 * len(rdp))
    m.lui(T7, 0x0004)                                    # pause (~1 image)
    m.label("delay"); m.addiu(T7, T7, -1); m.branch(5, T7, 0, "delay")
    m.branch(4, 0, 0, "main")
    m.label("boutons")
    for name in N64_COLORS:
        m.op(rgba5551_pair(name))
    stick_tables(m, rgba5551_pair)
    code = m.resolve()
    assert len(code) <= 0x1000 - 0x40, len(code)

    header = bytearray(0x40)
    struct.pack_into(">IIII", header, 0, 0x80371240, 0x0000000F, 0x80000400, 0x00001444)
    header[0x20:0x34] = b"PLAYTENDO TEST".ljust(20)
    header[0x3B:0x3F] = b"NPTE"
    rom = bytes(header) + code
    return rom + bytes(0x100000 - len(rom))


# --------------------------------------------------------------- PSP (MIPS Allegrex, ELF)
# Boutons (bits 15 → 0) : carré, croix, rond, triangle, 2 inutilisés, R, L, gauche, bas, droite, haut,
# Start, 2 inutilisés, Select. Mêmes couleurs que la PS1 (croix = B vert, rond = A rouge…).
PSP_COLORS = ["cyan", "vert", "rouge", "jaune", "bleu", "bleu", "violet", "orange",
              "vert foncé", "marron", "bleu clair", "rose", "blanc", "bleu", "bleu", "gris"]


def psp_elf():
    """Programme PSP au format ELF : il appelle l'écran et la manette du système (fonctions
    désignées par leur « NID »), lit la manette et remplit l'écran d'une couleur."""
    base = 0x08804000
    m = MipsAsm(base)
    A0, A1, A2, A3 = m.A0, m.A1, m.A2, m.A3
    T0, T1, T2, T3, T4, T5, T6, T7 = m.T0, m.T1, m.T2, m.T3, m.T4, m.T5, m.T6, m.T7

    m.ori(A0, 0, 0); m.ori(A1, 0, 480); m.ori(A2, 0, 272); m.jal("sceDisplaySetMode")
    m.lui(A0, 0x0400); m.ori(A1, 0, 512); m.ori(A2, 0, 3); m.ori(A3, 0, 1); m.jal("sceDisplaySetFrameBuf")
    m.ori(A0, 0, 0); m.jal("sceCtrlSetSamplingCycle")
    m.ori(A0, 0, 1); m.jal("sceCtrlSetSamplingMode")     # avec le stick analogique

    m.label("main")
    m.la(A0, "pad"); m.ori(A1, 0, 1); m.jal("sceCtrlReadBufferPositive")
    m.la(T0, "pad")
    m.lw(T3, 4, T0)                                      # boutons
    m.ori(T5, 0, 0x8000)
    m.la(T6, "boutons")
    m.label("find")
    m.and_(T7, T3, T5)
    m.branch(5, T7, 0, "found")
    m.srl(T5, T5, 1)
    m.addiu(T6, T6, 4)
    m.branch(5, T5, 0, "find")
    m.lbu(T7, 8, T0)                                     # stick X : 0 à gauche, 255 à droite
    m.la(T6, "stick_gauche"); m.slti(T1, T7, 64); m.branch(5, T1, 0, "found")
    m.la(T6, "stick_droite"); m.slti(T1, T7, 193); m.branch(4, T1, 0, "found")
    m.lbu(T7, 9, T0)                                     # stick Y : 0 en haut
    m.la(T6, "stick_haut"); m.slti(T1, T7, 64); m.branch(5, T1, 0, "found")
    m.la(T6, "stick_bas"); m.slti(T1, T7, 193); m.branch(4, T1, 0, "found")
    m.la(T6, "repos")
    m.label("found")
    m.lw(T6, 0, T6)
    m.lui(T0, 0x4400)                                    # mémoire vidéo, sans cache
    m.load32(T1, 512 * 272)
    m.label("fill")
    m.sw(T6, 0, T0)
    m.addiu(T0, T0, 4)
    m.addiu(T1, T1, -1)
    m.branch(5, T1, 0, "fill")
    m.jal("sceDisplayWaitVblankStart")
    m.branch(4, 0, 0, "main")

    def color(name): return 0xFF000000 | bgr24(name)    # pixel 8888 : R, G, B, A en mémoire
    m.label("boutons")
    for name in PSP_COLORS:
        m.op(color(name))
    stick_tables(m, color)

    # Petites fonctions « relais » que le système remplace par ses propres fonctions.
    imports = [("sceDisplay", [("sceDisplaySetMode", 0x0E20F177), ("sceDisplaySetFrameBuf", 0x289D82FE),
                               ("sceDisplayWaitVblankStart", 0x984C27E7)]),
               ("sceCtrl", [("sceCtrlSetSamplingCycle", 0x6A2774F3), ("sceCtrlSetSamplingMode", 0x1F4011E6),
                            ("sceCtrlReadBufferPositive", 0x1F803938)])]
    for library, functions in imports:
        m.label(f"stubs_{library}")
        for name, _ in functions:
            m.label(name)
            m.jr(m.RA); m.nop()
        m.label(f"nids_{library}")
        for _, nid in functions:
            m.op(nid)
        m.label(f"name_{library}")
        m.data(library.encode() + b"\0")
    m.label("libstub")
    for library, functions in imports:
        m.addr(f"name_{library}")
        m.op(0x4001 << 16 | 0x0011)                      # version, attributs
        m.op(len(functions) << 16 | 0 << 8 | 5)          # taille de l'entrée (5 mots), 0 variable, n fonctions
        m.addr(f"nids_{library}")
        m.addr(f"stubs_{library}")
    m.label("libstub_end")
    m.label("modinfo")
    m.op(0x0101 << 16 | 0x0000)                          # attributs, version
    m.data(b"PlayTendoTest".ljust(28, b"\0"))
    m.op(0)                                              # gp
    m.addr("libstub"); m.addr("libstub")                 # aucune fonction exportée
    m.addr("libstub"); m.addr("libstub_end")
    m.label("pad")
    m.data(bytes(16))                                    # état de la manette (SceCtrlData)
    body = m.resolve()

    offset = 0x100
    modinfo_offset = offset + m.labels["modinfo"] - base
    elf = bytearray(offset)
    elf[0:16] = b"\x7fELF\x01\x01\x01" + bytes(9)
    struct.pack_into("<HHIIIIIHHHHHH", elf, 16, 2, 8, 1, base, 52, 0, 0x10A23001, 52, 32, 1, 40, 0, 0)
    struct.pack_into("<IIIIIIII", elf, 52, 1, offset, base, modinfo_offset, len(body), len(body), 7, 16)
    return bytes(elf) + body


for name, data in [("test.nes", nes()), ("test.sfc", snes()), ("test.gb", gameboy()),
                   ("test.gba", gba()), ("test.nds", nds()), ("test.exe", ps1_exe()),
                   ("test.z64", n64()), ("test.elf", psp_elf())]:
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)
    print(f"{name:10s} {len(data):7d} octets")

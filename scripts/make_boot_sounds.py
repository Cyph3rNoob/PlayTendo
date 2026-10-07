#!/usr/bin/env python3
"""Sons de démarrage proposés pour PlayTendo : synthèse maison (aucun échantillon extérieur), calée sur l'animation
de démarrage (BootView) : l'écran s'ouvre à 0,41 s, étincelle à 0,81 s, titre écrit de 0,96 à 1,46 s, fondu
jusqu'à ~2,5 s. Usage : make_boot_sounds.py <dossier de sortie>

Choisi par l'utilisateur le 2026-10-07 : n° 4 « Puissance », dans sa version 4b « Puissance iPhone » (la 4 n'était
presque que du grave : sur le haut-parleur de l'iPhone, il n'en restait que deux notes aiguës). Dans l'app :
  afconvert -f m4af -d aac -b 128000 "<dossier>/4b - Puissance iPhone.wav" app/PlayTendo/Resources/BootSound.m4a"""
import math
import os
import random
import struct
import sys
import wave

SR = 44100
TAU = 2 * math.pi
OPEN, SPARK, TITLE = 0.41, 0.81, 0.96
random.seed(7)


def hz(note):
    return 440.0 * 2 ** ((note - 69) / 12)


def adsr(t, length, a, d, s, r):
    if t < a:
        v = t / a
    elif t < a + d:
        v = 1 - (1 - s) * (t - a) / d
    else:
        v = s
    if t > length - r:
        v *= max(0.0, (length - t) / r)
    return v


def poly_blep(t, dt):
    if t < dt:
        t /= dt
        return t + t - t * t - 1.0
    if t > 1 - dt:
        t = (t - 1) / dt
        return t * t + t + t + 1.0
    return 0.0


def osc(kind, freq, seconds, amp, duty=0.5):
    """Oscillateur : sin, saw, sqr (adouci), sq8 (carré brut, son 8 bits), tri. `freq` et `amp` : nombre ou f(t)."""
    n = int(seconds * SR)
    out = [0.0] * n
    ph = random.random()
    for i in range(n):
        t = i / SR
        f = freq(t) if callable(freq) else freq
        dt = f / SR
        if kind == "sin":
            v = math.sin(TAU * ph)
        elif kind == "saw":
            v = 2 * ph - 1 - poly_blep(ph, dt)
        elif kind == "sqr":
            v = (1.0 if ph < duty else -1.0) + poly_blep(ph, dt) - poly_blep((ph - duty) % 1.0, dt)
        elif kind == "sq8":
            v = 1.0 if ph < duty else -1.0
        else:
            v = 4 * abs(ph - 0.5) - 1
        out[i] = v * (amp(t) if callable(amp) else amp)
        ph += dt
        ph -= int(ph)
    return out


def noise(seconds, amp=1.0):
    return [random.uniform(-1, 1) * (amp(i / SR) if callable(amp) else amp) for i in range(int(seconds * SR))]


def lowpass(x, cutoff, poles=2):
    for _ in range(poles):
        y = 0.0
        out = [0.0] * len(x)
        for i, v in enumerate(x):
            fc = cutoff(i / SR) if callable(cutoff) else cutoff
            y += (1 - math.exp(-TAU * fc / SR)) * (v - y)
            out[i] = y
        x = out
    return x


def highpass(x, cutoff):
    low = lowpass(x, cutoff, poles=1)
    return [a - b for a, b in zip(x, low)]


def bell(f, seconds, ratio=2.0, index=2.0, decay=1.0, amp=1.0):
    """Clochette en modulation de fréquence."""
    n = int(seconds * SR)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        mod = index * math.exp(-t / (decay * 0.35))
        out[i] = amp * min(1.0, t / 0.002) * math.exp(-t / decay) * math.sin(TAU * f * t + mod * math.sin(TAU * f * ratio * t))
    return out


def mixed(*voices):
    n = max(len(v) for v in voices)
    out = [0.0] * n
    for v in voices:
        for i, s in enumerate(v):
            out[i] += s
    return out


class Mix:
    def __init__(self, seconds, room=0.84, damp=0.25):
        self.n = int(SR * seconds)
        self.dry = [0.0] * self.n
        self.send = [0.0] * self.n
        self.room, self.damp = room, damp
        self.limit = 0.0  # compression douce à l'écriture (0 : aucune)

    def add(self, start, samples, gain=1.0, rev=0.3):
        i0 = int(start * SR)
        for i, v in enumerate(samples):
            j = i0 + i
            if j >= self.n:
                break
            self.dry[j] += v * gain
            self.send[j] += v * gain * rev

    def reverb(self, spread):
        """Réverbération type Freeverb (8 filtres en peigne, 4 passe-tout) : un canal."""
        x = self.send
        acc = [0.0] * self.n
        for d in (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617):
            d += spread
            buf, idx, store = [0.0] * d, 0, 0.0
            for i, v in enumerate(x):
                o = buf[idx]
                store = o * (1 - self.damp) + store * self.damp
                buf[idx] = v * 0.015 + store * self.room
                idx = idx + 1 if idx + 1 < d else 0
                acc[i] += o
        for d in (556, 441, 341, 225):
            d += spread
            buf, idx = [0.0] * d, 0
            for i in range(self.n):
                b = buf[idx]
                inp = acc[i]
                acc[i] = -inp + b
                buf[idx] = inp + b * 0.5
                idx = idx + 1 if idx + 1 < d else 0
        return acc

    def write(self, path, wet=3.0):
        left, right = self.reverb(0), self.reverb(23)
        frames = []
        fade = int(0.25 * SR)
        peak = 1e-9
        stereo = []
        for i in range(self.n):
            g = min(1.0, (self.n - i) / fade)
            l = (self.dry[i] + left[i] * wet) * g
            r = (self.dry[i] + right[i] * wet) * g
            stereo.append((l, r))
            peak = max(peak, abs(l), abs(r))
        if self.limit:
            # Compression douce : rapproche les passages faibles des forts (plus audible sur un petit haut-parleur).
            norm = math.tanh(self.limit)
            stereo = [(math.tanh(self.limit * l / peak) / norm, math.tanh(self.limit * r / peak) / norm) for l, r in stereo]
            peak = max(max(abs(l), abs(r)) for l, r in stereo)
        scale = 0.89 / peak
        for l, r in stereo:
            frames.append(struct.pack("<hh", int(l * scale * 32767), int(r * scale * 32767)))
        with wave.open(path, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(b"".join(frames))


def neon():
    """1. Néon : l'écran grésille et monte, décharge électrique, grand accord de synthé lumineux, scintillement."""
    m = Mix(3.4)
    rise = osc("saw", lambda t: 70 + 150 * (t / 0.45) ** 2, 0.47, lambda t: 0.22 * min(1, t / 0.45) ** 1.5)
    m.add(0, lowpass(rise, lambda t: 150 + 1800 * (t / 0.45) ** 2), rev=0.2)
    m.add(OPEN, osc("sin", lambda t: 2400 * math.exp(-t / 0.03) + 300, 0.15, lambda t: 0.35 * math.exp(-t / 0.04)), rev=0.3)
    m.add(OPEN, highpass(noise(0.1, lambda t: 0.3 * math.exp(-t / 0.02)), 3000), rev=0.3)
    voices = []
    for note in (50, 57, 62, 66, 69, 76):  # ré, la, ré, fa#, la, mi
        for detune in (-0.08, 0.08):
            voices.append(osc("saw", hz(note + detune), 2.6, lambda t: 0.1 * adsr(t, 2.6, 0.03, 0.6, 0.6, 1.2)))
    pad = lowpass(mixed(*voices), lambda t: 450 + 3200 * (1 - math.exp(-t / 0.2)) * math.exp(-t / 2.2))
    m.add(SPARK, pad, rev=0.45)
    m.add(SPARK, osc("sin", hz(38), 1.8, lambda t: 0.35 * math.exp(-t / 0.7) * min(1, t / 0.01)), rev=0.05)
    for k, note in enumerate((86, 90, 93, 98, 102)):
        m.add(TITLE + k * 0.1, osc("tri", hz(note), 0.6, lambda t: 0.09 * math.exp(-t / 0.18) * min(1, t / 0.003)), rev=0.6)
    return m


def cristal():
    """2. Cristal : souffle léger, déclic, trois clochettes claires qui montent, nappe douce."""
    m = Mix(3.4, room=0.87)
    air = highpass(lowpass(noise(0.43, lambda t: 0.12 * min(1, t / 0.4) ** 2), lambda t: 400 + 5000 * (t / 0.43) ** 2), 300)
    m.add(0, air, rev=0.5)
    m.add(OPEN, osc("sin", 3200, 0.03, lambda t: 0.25 * math.exp(-t / 0.004)), rev=0.4)
    for delay, note in ((0.0, 81), (0.09, 88), (0.18, 93), (0.18, 97)):  # la, mi, la + do#
        m.add(SPARK + delay, bell(hz(note), 2.2, ratio=2.0, index=2.2, decay=0.8, amp=0.22), rev=0.5)
    m.add(SPARK + 0.55, bell(hz(100), 1.5, ratio=2.0, index=1.5, decay=0.5, amp=0.06), rev=0.7)
    for note in (57, 64, 69):
        m.add(SPARK, osc("sin", hz(note), 2.4, lambda t: 0.07 * adsr(t, 2.4, 0.35, 0.5, 0.7, 1.2)), rev=0.4)
    return m


def chip():
    """3. 8 bits : bips qui montent par paliers, coup de bruit, arpège rapide, accord final qui vibre."""
    m = Mix(3.0, room=0.7)
    for k, note in enumerate((48, 52, 55, 60, 64, 67, 72)):
        m.add(k * 0.055, osc("sq8", hz(note), 0.05, 0.1, duty=0.125), rev=0.05)
    m.add(OPEN, noise(0.12, lambda t: 0.35 * math.exp(-t / 0.03)), rev=0.1)
    for k, note in enumerate((79, 83, 86, 91)):
        m.add(0.47 + k * 0.075, osc("sq8", hz(note), 0.07, lambda t: 0.1 * (1 - t / 0.07), duty=0.25), rev=0.1)
    fade = lambda t: 1.0 if t < 0.5 else max(0.0, 1 - (t - 0.5) / 0.9)
    vib = lambda base: (lambda t: hz(base + (0.3 * math.sin(TAU * 5.5 * t) if t > 0.25 else 0)))
    final = mixed(osc("sq8", vib(79), 1.4, lambda t: 0.12 * fade(t)), osc("sq8", vib(86), 1.4, lambda t: 0.08 * fade(t), duty=0.25),
                  osc("tri", hz(55), 1.4, lambda t: 0.25 * fade(t)))
    m.add(SPARK, final, rev=0.12)
    m.add(SPARK + 0.18, final, gain=0.3, rev=0.1)  # écho
    return m


def power():
    """4. Puissance : grondement et souffle qui montent, battement sourd, gros impact grave, nappe sombre et large."""
    m = Mix(3.6, room=0.88)
    m.add(0, osc("sin", lambda t: 32 + 25 * t / 0.81, 0.83, lambda t: 0.5 * min(1, t / 0.81) ** 2), rev=0.1)
    riser = lowpass(noise(0.83, lambda t: 0.25 * min(1, t / 0.81) ** 3), lambda t: 200 + 5000 * min(1, t / 0.81) ** 3)
    m.add(0, riser, rev=0.3)
    m.add(OPEN, osc("sin", lambda t: 90 * math.exp(-t / 0.05) + 45, 0.3, lambda t: 0.5 * math.exp(-t / 0.08)), rev=0.2)
    m.add(SPARK, osc("sin", lambda t: 45 + 110 * math.exp(-t / 0.03), 2.0, lambda t: 0.9 * math.exp(-t / 0.55) * min(1, t / 0.003)), rev=0.25)
    m.add(SPARK, lowpass(noise(0.4, lambda t: 0.5 * math.exp(-t / 0.06)), 2500), rev=0.5)
    voices = []
    for note in (40, 47, 52, 54, 59):  # mi, si, mi, fa#, si
        for detune in (-0.06, 0.06):
            voices.append(osc("saw", hz(note + detune), 2.6, lambda t: 0.09 * adsr(t, 2.6, 0.15, 0.8, 0.6, 1.3)))
    m.add(SPARK, lowpass(mixed(*voices), lambda t: 300 + 900 * (1 - math.exp(-t / 0.4))), rev=0.45)
    m.add(SPARK + 0.25, bell(hz(88), 1.6, decay=0.6, amp=0.05), rev=0.7)
    m.add(SPARK + 0.37, bell(hz(95), 1.6, decay=0.6, amp=0.05), rev=0.7)
    return m


def saturate(x, drive):
    """Saturation douce : ajoute des harmoniques, que l'oreille entend comme du grave même sur un petit haut-parleur."""
    norm = math.tanh(drive)
    return [math.tanh(drive * v) / norm for v in x]


def power_phone():
    """4b. Puissance pour haut-parleur d'iPhone (qui ne rend presque rien sous 300 Hz : seules les deux notes aiguës
    de « Puissance » y restaient). Les basses n'y gardent que leurs harmoniques (au-dessus de 150 Hz), que l'oreille
    entend comme du grave même sur un petit haut-parleur, plus une infrabasse discrète pour un casque ou des
    enceintes ; choc avec du corps, nappe une octave plus haut."""
    m = Mix(3.6, room=0.88)

    def harmonics(x, drive):
        return lowpass(highpass(highpass(saturate(x, drive), 150), 150), 2500)

    rise = osc("sin", lambda t: 40 + 40 * t / 0.81, 0.83, lambda t: min(1, t / 0.81) ** 2)
    m.add(0, harmonics(rise, 5), gain=0.35, rev=0.15)
    m.add(0, rise, gain=0.08, rev=0.05)
    riser = lowpass(noise(0.83, lambda t: 0.3 * min(1, t / 0.81) ** 3), lambda t: 400 + 7000 * min(1, t / 0.81) ** 3)
    m.add(0, riser, rev=0.3)
    thump = osc("sin", lambda t: 90 * math.exp(-t / 0.05) + 45, 0.3, lambda t: math.exp(-t / 0.08))
    m.add(OPEN, harmonics(thump, 5), gain=0.5, rev=0.2)
    m.add(OPEN, thump, gain=0.12, rev=0.1)
    m.add(OPEN, lowpass(noise(0.08, lambda t: 0.4 * math.exp(-t / 0.015)), 1200), rev=0.2)
    boom = osc("sin", lambda t: 45 + 110 * math.exp(-t / 0.03), 2.0, lambda t: math.exp(-t / 0.55) * min(1, t / 0.003))
    m.add(SPARK, harmonics(boom, 6), gain=0.7, rev=0.3)
    m.add(SPARK, boom, gain=0.15, rev=0.2)
    body = osc("saw", lambda t: 70 + 60 * math.exp(-t / 0.04), 0.8, lambda t: math.exp(-t / 0.18) * min(1, t / 0.003))
    m.add(SPARK, lowpass(highpass(highpass(body, 150), 150), 1200), gain=0.6, rev=0.35)
    m.add(SPARK, lowpass(noise(0.5, lambda t: 0.6 * math.exp(-t / 0.08)), 4500), rev=0.5)
    voices = []
    for note in (52, 59, 64, 66, 71):  # mi, si, mi, fa#, si (une octave plus haut que « Puissance »)
        for detune in (-0.06, 0.06):
            voices.append(osc("saw", hz(note + detune), 2.6, lambda t: 0.11 * adsr(t, 2.6, 0.15, 0.8, 0.6, 1.3)))
    m.add(SPARK, lowpass(mixed(*voices), lambda t: 500 + 2200 * (1 - math.exp(-t / 0.4))), rev=0.45)
    m.add(SPARK + 0.25, bell(hz(88), 1.6, decay=0.6, amp=0.025), rev=0.7)
    m.add(SPARK + 0.37, bell(hz(95), 1.6, decay=0.6, amp=0.025), rev=0.7)
    m.limit = 3.0
    return m


def discret():
    """5. Discret : petit déclic, puis « bip-biiip » doux. Court."""
    m = Mix(1.9, room=0.75)
    m.add(OPEN, highpass(noise(0.01, lambda t: 0.25 * math.exp(-t / 0.002)), 2000), rev=0.2)
    soft = lambda f, seconds, amp: mixed(osc("sin", f, seconds, amp), osc("sin", (lambda t: 3 * f(t)) if callable(f) else 3 * f, seconds,
                                                                          (lambda t: 0.2 * amp(t))))
    m.add(SPARK, soft(hz(84), 0.09, lambda t: 0.25 * min(1, t / 0.004) * math.exp(-t / 0.04)), rev=0.25)
    glide = lambda t: hz(89 + 2 * min(1, t / 0.025))
    m.add(SPARK + 0.1, soft(glide, 0.5, lambda t: 0.25 * min(1, t / 0.004) * math.exp(-t / 0.2)), rev=0.25)
    return m


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for number, name, make in (("1", "Neon", neon), ("2", "Cristal", cristal), ("3", "8-bits", chip),
                               ("4", "Puissance", power), ("4b", "Puissance iPhone", power_phone),
                               ("5", "Discret", discret)):
        path = os.path.join(out, f"{number} - {name}.wav")
        make().write(path)
        print(path)

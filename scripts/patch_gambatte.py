#!/usr/bin/env python3
"""Retouches de Gambatte (libretro) pour PlayTendo. Appelé par build_cores.sh et build_cores_macos.sh ; une retouche
déjà faite est sautée.

1. net_serial.cpp (2026-10-24, audit de sécurité) : en hôte du câble link, Gambatte écoutait sur toutes les interfaces
   (INADDR_ANY) : n'importe qui sur le même réseau pouvait se brancher à la partie sans passer par PlayTendo. Il
   n'écoute plus que l'appareil lui-même (127.0.0.1) ; PlayTendo relaie l'autre appareil, après accord du joueur.
2. net_serial.cpp (2026-10-25) : port de l'hôte réutilisable tout de suite (SO_REUSEADDR) : rebrancher juste après une
   coupure échouait tant que l'ancienne liaison restait en attente de fermeture (TIME_WAIT).
3. net_serial.cpp (2026-10-25, son essai iPhone ↔ Mac : le Game Boy qui rejoint restait figé) : l'hôte ne décrochait la
   connexion qu'une fois toutes les 5 s de *temps processeur* (clock()), et seulement quand son jeu se servait du
   câble ; pendant ce temps, l'autre Game Boy attendait sa réponse, bloqué. Décrochage essayé toutes les 50 ms de vraie
   durée (select à 0 : rien n'attend), nouvelle connexion du client toutes les 2 s, et octets envoyés sans délai
   (TCP_NODELAY) sur les deux bouts.
4. net_serial.cpp/.h, libretro.cpp (2026-10-25, son essai : quand l'autre quitte la salle d'échange, ce Game Boy figeait
   jusqu'à ce qu'il reparle à l'hôtesse) : Gambatte fait attendre un Game Boy qui envoie un octet jusqu'à la réponse de
   l'autre, qui ne répond que quand son jeu attend un transfert. Un vrai Game Boy dont le partenaire n'est pas prêt
   reçoit 0xFF et continue. `NetSerial::idle()`, appelé à chaque image : un octet de l'autre arrivé alors que ce jeu
   n'attend aucun transfert depuis 10 images (≈ 1/6 s) reçoit la réponse « vide » 0xFF. Pendant un échange, les deux
   jeux attendent leurs octets : rien ne change.

Usage : python3 scripts/patch_gambatte.py <sources/gambatte>
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent / "sources" / "gambatte")
path = root / "libgambatte" / "libretro" / "net_serial.cpp"
text = path.read_text(encoding="utf-8")
old = "\t\tserver_addr.sin_addr.s_addr = INADDR_ANY;"
new = "\t\tserver_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // PlayTendo : l'appareil seulement"
if new in text:
    print("net_serial.cpp : déjà limité à l'appareil")
elif text.count(old) == 1:
    text = text.replace(old, new)
    print("net_serial.cpp : câble link limité à l'appareil")
else:
    raise SystemExit("net_serial.cpp : retouche impossible (le fichier a changé)")

old = "\t\tif (bind(fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {"
new = ("\t\tint reuse = 1; // PlayTendo : port réutilisable tout de suite après une coupure\n"
       "\t\tsetsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));\n" + old)
if new in text:
    print("net_serial.cpp : port déjà réutilisable")
elif text.count(old) == 1:
    text = text.replace(old, new)
    print("net_serial.cpp : port réutilisable")
else:
    raise SystemExit("net_serial.cpp : retouche 2 impossible (le fichier a changé)")
path.write_text(text, encoding="utf-8")

# Retouche 3 : décrochage sans attente et envoi sans délai.
patches = [
    ("#include <netinet/in.h>\n#include <netdb.h>\n",
     "#include <netinet/in.h>\n#include <netinet/tcp.h>\n#include <netdb.h>\n#include <chrono>\n"),
    ("\tif (sockfd_ < 0 && throttle) {\n"
     "\t\tclock_t now = clock();\n"
     "\t\t// Only attempt to establish the connection every 5 seconds\n"
     "\t\tif (((now - lastConnectAttempt_) / CLOCKS_PER_SEC) < 5) {\n"
     "\t\t\treturn false;\n"
     "\t\t}\n"
     "\t}\n"
     "\tlastConnectAttempt_ = clock();\n",
     "\t// PlayTendo : en vraie durée (clock() comptait le temps processeur de toute l'app) ; l'hôte essaie de décrocher\n"
     "\t// toutes les 50 ms (accept sans attente), le client de se connecter toutes les 2 s.\n"
     "\tif (sockfd_ < 0 && throttle) {\n"
     "\t\tlong long now = std::chrono::duration_cast<std::chrono::milliseconds>(\n"
     "\t\t\tstd::chrono::steady_clock::now().time_since_epoch()).count();\n"
     "\t\tif (now - (long long)lastConnectAttempt_ < (is_server_ ? 50 : 2000)) {\n"
     "\t\t\treturn false;\n"
     "\t\t}\n"
     "\t}\n"
     "\tlastConnectAttempt_ = (clock_t)std::chrono::duration_cast<std::chrono::milliseconds>(\n"
     "\t\tstd::chrono::steady_clock::now().time_since_epoch()).count();\n"),
    ("\t\tgambatte_log(RETRO_LOG_INFO, \"GameLink network server connected to client!\\n\");\n",
     "\t\tint nodelay = 1; // PlayTendo : octets envoyés sans délai\n"
     "\t\tsetsockopt(sockfd_, IPPROTO_TCP, TCP_NODELAY, (const char *)&nodelay, sizeof(nodelay));\n"
     "\t\tgambatte_log(RETRO_LOG_INFO, \"GameLink network server connected to client!\\n\");\n"),
    ("\t\tsockfd_ = fd;\n\t\tgambatte_log(RETRO_LOG_INFO, \"GameLink network client connected to server!\\n\");\n",
     "\t\tsockfd_ = fd;\n"
     "\t\tint nodelay = 1; // PlayTendo : octets envoyés sans délai\n"
     "\t\tsetsockopt(sockfd_, IPPROTO_TCP, TCP_NODELAY, (const char *)&nodelay, sizeof(nodelay));\n"
     "\t\tgambatte_log(RETRO_LOG_INFO, \"GameLink network client connected to server!\\n\");\n"),
]
for old, new in patches:
    if new in text:
        continue
    if text.count(old) != 1:
        raise SystemExit("net_serial.cpp : retouche 3 impossible (le fichier a changé) :\n" + old)
    text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
print("net_serial.cpp : décrochage sans attente, envoi sans délai")

# Retouche 4 : réponse « vide » aux octets que ce jeu n'attend pas.
header = root / "libgambatte" / "libretro" / "net_serial.h"
htext = header.read_text(encoding="utf-8")
hold = "\t\tvirtual unsigned char send(unsigned char data, bool fastCgb);\n"
hnew = (hold + "\t\t/// PlayTendo : à chaque image, réponse « vide » (0xFF) aux octets de l'autre Game Boy que ce jeu n'attend pas.\n"
        "\t\tvoid idle();\n")
hold2 = "\t\tclock_t lastConnectAttempt_;\n"
hnew2 = hold2 + "\t\tbool waitedThisFrame_;\n\t\tint idleFrames_;\n"
for old, new in ((hold, hnew), (hold2, hnew2)):
    if new in htext:
        continue
    if htext.count(old) != 1:
        raise SystemExit("net_serial.h : retouche 4 impossible (le fichier a changé)")
    htext = htext.replace(old, new)
header.write_text(htext, encoding="utf-8")

idle = (
    "\n"
    "// PlayTendo : un vrai Game Boy dont le partenaire n'attend pas de transfert reçoit 0xFF et continue ; Gambatte,\n"
    "// lui, ferait attendre l'autre Game Boy (jeu figé) jusqu'à ce que ce jeu-ci se serve du câble. Un octet arrivé alors\n"
    "// que ce jeu n'attend aucun transfert depuis 10 images reçoit donc la réponse « vide ».\n"
    "void NetSerial::idle()\n"
    "{\n"
    "\tif (is_stopped_ || sockfd_ < 0 || waitedThisFrame_) {\n"
    "\t\twaitedThisFrame_ = false;\n"
    "\t\tidleFrames_ = 0;\n"
    "\t\treturn;\n"
    "\t}\n"
    "\tint bytes_avail = 0;\n"
    "\tif (ioctl(sockfd_, FIONREAD, &bytes_avail) < 0 || bytes_avail < 2) {\n"
    "\t\tidleFrames_ = 0;\n"
    "\t\treturn;\n"
    "\t}\n"
    "\tif (++idleFrames_ < 10) {\n"
    "\t\treturn;\n"
    "\t}\n"
    "\tidleFrames_ = 0;\n"
    "\tunsigned char buffer[2];\n"
    "\tif (read(sockfd_, buffer, 2) <= 0) {\n"
    "\t\tgambatte_log(RETRO_LOG_ERROR, \"Error reading from socket: %s\\n\", strerror(errno));\n"
    "\t\tclose(sockfd_);\n"
    "\t\tsockfd_ = -1;\n"
    "\t\treturn;\n"
    "\t}\n"
    "\tbuffer[0] = 0xFF;\n"
    "\tbuffer[1] = 128;\n"
    "\tif (write(sockfd_, buffer, 2) <= 0) {\n"
    "\t\tgambatte_log(RETRO_LOG_ERROR, \"Error writing to socket: %s\\n\", strerror(errno));\n"
    "\t\tclose(sockfd_);\n"
    "\t\tsockfd_ = -1;\n"
    "\t}\n"
    "}\n"
)
patches = [
    (", lastConnectAttempt_(0)\n", ", lastConnectAttempt_(0)\n, waitedThisFrame_(false)\n, idleFrames_(0)\n"),
    ("bool NetSerial::check(unsigned char out, unsigned char& in, bool& fastCgb)\n{\n",
     "bool NetSerial::check(unsigned char out, unsigned char& in, bool& fastCgb)\n{\n"
     "\twaitedThisFrame_ = true; // PlayTendo : ce jeu attend un transfert (voir idle)\n"),
]
for old, new in patches:
    if new in text:
        continue
    if text.count(old) != 1:
        raise SystemExit("net_serial.cpp : retouche 4 impossible (le fichier a changé) :\n" + old)
    text = text.replace(old, new)
if "void NetSerial::idle()" not in text:
    text = text.rstrip("\n") + "\n" + idle
path.write_text(text, encoding="utf-8")

core = root / "libgambatte" / "libretro" / "libretro.cpp"
ctext = core.read_text(encoding="utf-8")
cold = "#ifdef DUAL_MODE\n   while (gb2.runFor("
cnew = ("#ifdef HAVE_NETWORK\n"
        "   // PlayTendo : réponse « vide » aux octets de l'autre Game Boy que ce jeu n'attend pas (NetSerial::idle).\n"
        "   gb_net_serial.idle();\n"
        "#endif\n" + cold)
if cnew not in ctext:
    if ctext.count(cold) != 1:
        raise SystemExit("libretro.cpp : retouche 4 impossible (le fichier a changé)")
    core.write_text(ctext.replace(cold, cnew), encoding="utf-8")
print("net_serial.cpp, libretro.cpp : réponse « vide » aux octets que ce jeu n'attend pas")

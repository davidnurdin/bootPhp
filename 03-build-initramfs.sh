#!/usr/bin/env bash
# 03-build-initramfs.sh -- assemble the busybox root tree (no initramfs
# anymore: the kernel boots with root=UUID=<p4> directly, and init= points
# straight into this directory). /init mounts proc/sys/dev, remounts /
# rw when possible (fails harmlessly under QEMU, where the real disk is
# passed read-only since the host has it live-mounted), then drops to an
# interactive busybox shell. PATH is forced to this tree's own bin/sbin
# so bare command names (mount, sh, ls...) resolve to busybox, not to the
# real system's own binaries also present on the same filesystem.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BB_VERSION="1.37.0"
BB_INSTALL="$HERE/src/busybox-${BB_VERSION}/_install"
ROOTFS="$HERE/initramfs/rootfs"

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

# Busybox's own install tree already has bin/, sbin/, usr/{bin,sbin} with
# the busybox binary + applet symlinks.
cp -a "$BB_INSTALL"/. "$ROOTFS"/

mkdir -p "$ROOTFS"/{proc,sys,dev,tmp,root,lib/firmware/intel,etc}

# reboot/poweroff/halt (par defaut de simples symlinks vers busybox) se
# comportent en mode "sysvinit" sans -f : ils envoient un signal a PID 1
# et attendent qu'IL orchestre l'arret. Notre init (une simple boucle
# "while true; do sh; done") n'installe aucun handler de signal -- or le
# noyau Linux ignore par convention les signaux a action par defaut
# "terminer" envoyes a PID 1 tant qu'aucun handler n'est installe, donc
# ce signal ne ferait rien et la commande resterait bloquee. On remplace
# les 3 applets par un petit wrapper qui force -f : l'appel syscall
# reboot()/poweroff direct, sans dependre d'un init cooperatif.
for applet in reboot poweroff halt; do
    rm -f "$ROOTFS/sbin/$applet"
    cat > "$ROOTFS/sbin/$applet" << WRAP
#!$ROOTFS/bin/sh
exec $ROOTFS/bin/busybox $applet -f "\$@"
WRAP
    chmod +x "$ROOTFS/sbin/$applet"
done

# Intel Bluetooth firmware (BE200 combo card). Redundant now that root=
# is the real p4 filesystem (which already has its own /lib/firmware),
# but harmless to keep -- makes this tree self-contained if ever reused
# standalone (e.g. on its own partition/image later).
if ls /lib/firmware/intel/ibt-* >/dev/null 2>&1; then
    cp /lib/firmware/intel/ibt-* "$ROOTFS/lib/firmware/intel/"
fi

# Disposition clavier AZERTY (fr) -- reprise du keymap actuellement
# charge sur cette machine (busybox n'a que l'applet "loadkmap", qui lit
# le format binaire "bkeymap"; on le genere avec dumpkeys+loadkeys -b
# plutot que de reparser le fichier cache de console-setup, qui contient
# des keysyms -- ex: "trademark" -- que ce loadkeys ne reconnait pas).
if command -v dumpkeys >/dev/null 2>&1 && command -v loadkeys >/dev/null 2>&1; then
    TMP_KEYMAP="$(mktemp)"
    dumpkeys > "$TMP_KEYMAP"
    loadkeys -b "$TMP_KEYMAP" > "$ROOTFS/etc/azerty.bmap" 2>/dev/null
    rm -f "$TMP_KEYMAP"
    echo "Keymap AZERTY embarque: $(wc -c < "$ROOTFS/etc/azerty.bmap") octets"
else
    echo "ATTENTION: dumpkeys/loadkeys absents, pas de keymap AZERTY embarque"
fi

# ROOTFS_PATH is baked in literally (this exact absolute path, from the
# perspective of the REAL root once mounted -- i.e. /root/... on p4
# itself) because init= runs long before any PATH is set, and the
# shebang line below needs busybox's own /bin/sh, not p4's real one.
cat > "$ROOTFS/init" << EOF
#!$ROOTFS/bin/sh
export PATH="$ROOTFS/bin:$ROOTFS/sbin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/fsMinimalKernel"

# Tout (sortie ET clavier) redirige explicitement sur tty1 (l'ecran +
# clavier physiques) plutot que sur /dev/console, pour ne pas dependre
# de quel "console=" est en dernier sur le cmdline. tty1 existe deja a
# ce stade (le noyau a deja auto-monte son propre devtmpfs sur / avant
# meme de lancer cet init, via CONFIG_DEVTMPFS_MOUNT). Tout est reduit
# au silence (stderr y compris) pour un boot le plus discret possible.
exec >/dev/tty1 2>/dev/null </dev/tty1

# Cache le curseur texte clignotant de la console (en plus de
# "vt.global_cursor_default=0" sur la ligne de commande noyau -- ceci
# est la sequence ANSI standard, ceinture et bretelles).
printf '\033[?25l' 2>/dev/null

# Noircit l'ecran IMMEDIATEMENT (avant meme /proc, /sys...), le temps
# que rainbow.php se lance et le redessine. Sans ca, quelques lignes de
# dmesg qui auraient echappe a "quiet" (certains drivers, Bluetooth
# inclus, impriment parfois a un niveau que "quiet" ne filtre pas)
# resteraient visibles une fraction de seconde avant d'etre ecrasees.
# /dev/fb0 existe deja (devtmpfs deja monte par le noyau) ; "dd" sans
# "count" ecrit des zeros jusqu'a ce que le peripherique refuse (fin du
# framebuffer), donc ca marche quelle que soit la resolution reelle.
dd if=/dev/zero of=/dev/fb0 bs=1M 2>/dev/null

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -o remount,rw / 2>/dev/null

if [ -f "$ROOTFS/etc/azerty.bmap" ]; then
    loadkmap < "$ROOTFS/etc/azerty.bmap" 2>/dev/null
fi

# PAS de "exec" ici: exec remplacerait ce script, qui EST le processus
# init (PID 1, lance directement par le noyau via init=). Si ce qui
# tourne a sa place meurt (Ctrl+C, "exit"...), PID 1 mourrait avec, et
# le noyau reagit par panic("Attempted to kill init!") -- sur ce Dell ca
# se traduit par un reboot immediat (watchdog/firmware), pas un hang
# propre. En lancant les commandes SANS exec, dans une boucle, rien ne
# tue jamais PID 1: la boucle relance aussitot la suite.
#
# "setsid" est indispensable a chaque fois (pas juste la commande toute
# seule) : le sous-processus heriterait sinon de la session de PID 1,
# deja rattachee a /dev/tty1 AVEC PID 1 comme groupe de processus au
# premier plan -- en essayant de prendre le controle du terminal pour
# son propre job control (setpgid + tcsetpgrp), il le ferait depuis un
# groupe qui n'est pas encore celui au premier plan, et le noyau lui
# enverrait SIGTTOU, qui l'arrete silencieusement (etat "stoppe", pas
# tue) avant meme d'afficher quoi que ce soit : ecran fige pour
# toujours, sans plantage ni message. "setsid" cree une session TOUTE
# NEUVE, qui acquiert /dev/tty1 automatiquement et proprement des son
# ouverture -- sans ce piege.
#
# Par defaut : rainbow.php, en boucle (silencieux -- sa propre sortie
# est jetee, il ne montre jamais rien sur tty1 lui-meme, juste les
# pixels qu'il ecrit directement dans /dev/fb0). Ctrl+C l'interrompt
# (SIGINT, comportement par defaut de PHP) et bascule sur un shell
# busybox classique pour la maintenance ; "exit" depuis ce shell revient
# a rainbow.php.
#
# "stty -echo" avant rainbow.php: sans ca, chaque touche tapee au
# clavier serait quand meme renvoyee a l'ecran par le driver tty
# (l'echo local est une fonction du terminal, pas du programme qui lit
# dessus -- rainbow.php ne lit meme pas son entree), ce qui afficherait
# des caracteres par-dessus le dessin. Seul ISIG (Ctrl+C) reste actif.
# "stty echo" avant le shell de secours: un shell interactif normal a
# besoin de l'echo pour etre utilisable.
while true; do
    printf '\033[?25l' > /dev/tty1 2>/dev/null
    stty -echo < /dev/tty1 2>/dev/null
    setsid sh -c 'exec /fsMinimalKernel/php /fsMinimalKernel/rainbow.php </dev/tty1 >/dev/null 2>/dev/null'
    printf '\033[?25h' > /dev/tty1 2>/dev/null
    stty echo < /dev/tty1 2>/dev/null
    setsid sh -c 'exec sh </dev/tty1 >/dev/tty1 2>&1'
done
EOF
chmod +x "$ROOTFS/init"

echo
echo "=== arbre busybox pret (pas d'initramfs/initrd) ==="
echo "init installe : $ROOTFS/init"
du -sh "$ROOTFS"

#!/usr/bin/env bash
# 06-build-php.sh -- PHP 8.4 CLI, 100% statique, installe dans
# /fsMinimalKernel/php (sur p4, donc visible depuis le kernel minimal
# une fois root= monte). CLI seulement -- pas de fpm/cgi/phpdbg.
#
# Extensions incluses (toutes ont un .a statique stable sur Debian) :
# core/standard, date, pcre (bundle), json, session, tokenizer, ctype,
# filter, hash, posix, pcntl, Reflection/SPL, openssl, zlib,
# libxml/dom/simplexml/xmlreader/xmlwriter, sqlite3/pdo_sqlite, phar.
#
# Volontairement exclues :
#   - mbstring : Debian ne fournit pas libonig.a (statique), et PHP 8.x
#     n'embarque plus oniguruma en interne (contrairement aux tres
#     vieilles versions) -- impossible a lier 100% statique sans
#     compiler oniguruma nous-memes.
#   - curl : sa chaine de dependances statiques (krb5, ldap, gnutls,
#     idn2, p11-kit, libssh2...) est enorme et plusieurs .a manquent
#     purement et simplement sur Debian (libgssapi_krb5.a,
#     libunistring.a, libp11-kit.a) -- trop fragile pour "doit tourner
#     sans probleme".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHP_VERSION="8.4.25"
PHP_URL="https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz"
SRC="$HERE/src"
PDIR="$SRC/php-${PHP_VERSION}"
DEST_DIR="/fsMinimalKernel"
DEST="$DEST_DIR/php"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y \
    liblzma-dev libsqlite3-dev libssl-dev libxml2-dev zlib1g-dev \
    re2c bison >/dev/null

mkdir -p "$SRC"
cd "$SRC"
if [ ! -f "php-${PHP_VERSION}.tar.xz" ]; then
    curl -fSL -o "php-${PHP_VERSION}.tar.xz" "$PHP_URL"
fi
rm -rf "$PDIR"
tar xf "php-${PHP_VERSION}.tar.xz"
cd "$PDIR"

# -fno-PIE/-fno-pie/-no-pie : cette Debian compile par defaut en PIE
# (executable position-independant, donc dynamique) -- sans ca le
# binaire resterait "pie executable" dynamique quoi qu'on fasse cote
# LDFLAGS.
./configure \
    --prefix=/opt/php-static \
    --enable-cli \
    --disable-cgi \
    --disable-fpm \
    --disable-phpdbg \
    --disable-shared \
    --enable-static \
    --without-pear \
    --disable-opcache \
    --enable-filter \
    --enable-ctype \
    --enable-tokenizer \
    --enable-session \
    --enable-pcntl \
    --with-pcre-jit=yes \
    --with-zlib \
    --with-openssl \
    --with-libxml \
    --enable-dom \
    --enable-simplexml \
    --enable-xmlreader \
    --enable-xmlwriter \
    --with-pdo-sqlite \
    --without-curl \
    --without-mbstring \
    --without-pgsql \
    --without-mysqli \
    --without-pdo-mysql \
    CFLAGS="-fno-PIE -fno-pie -O2" \
    LDFLAGS="-static -no-pie" \
    LIBS="-llzma -lzstd -lm"

# "make" tout court compile tous les .o correctement, mais le lien
# FINAL du binaire "sapi/cli/php" passe par libtool, qui intercepte
# lui-meme le mot "-static" (chez libtool ca veut juste dire "prefere
# les .a de MES PROPRES libs internes au build", pas "lie le binaire
# final 100% statiquement") -- resultat: un binaire toujours
# dynamique, meme avec -static dans LDFLAGS. Le vrai equivalent
# libtool ("-all-static") est lui transmis tel quel a gcc, qui ne le
# reconnait pas. Bref: on laisse "make" faire tout le travail de
# compilation (le lien final echoue ou produit un binaire non-statique,
# les deux sont attendus et sans consequence), on recupere la commande
# de lien EXACTE qu'il a generee dans le log, on la rejoue nous-memes
# EN CONTOURNANT libtool (gcc direct, "-static" pris au pied de la
# lettre cette fois), avec les libs externes regroupees dans un
# -Wl,--start-group/--end-group pour resoudre les references
# circulaires (libssl/libcrypto <-> libzstd, notamment).
BUILD_LOG="$(mktemp)"
make -j"$(nproc)" sapi/cli/php > "$BUILD_LOG" 2>&1 || true

grep -m1 "mode=link" "$BUILD_LOG" \
    | sed -E \
        -e 's#^/bin/bash [^ ]*/libtool --silent --preserve-dup-deps --tag=CC --mode=link ##' \
        -e 's/ -export-dynamic//' \
        -e 's/-all-static/-static/' \
        -e 's/ -l[A-Za-z0-9_]+//g' \
        -e 's/ -Wl,--(start|end)-group//g' \
        -e 's# -o sapi/cli/php# -Wl,--start-group -llzma -lzstd -lm -lxml2 -lssl -lcrypto -lsqlite3 -lz -Wl,--end-group -o sapi/cli/php#' \
    > "$BUILD_LOG.relink.sh"

if [ ! -s "$BUILD_LOG.relink.sh" ]; then
    echo "ECHEC: impossible d'extraire la commande de lien depuis $BUILD_LOG"
    exit 1
fi

bash "$BUILD_LOG.relink.sh"
rm -f "$BUILD_LOG" "$BUILD_LOG.relink.sh"

file sapi/cli/php | grep -q "statically linked" || {
    echo "ECHEC: sapi/cli/php n'est pas statique -- voir sapi/cli/php ci-dessus"
    file sapi/cli/php
    exit 1
}

strip sapi/cli/php
mkdir -p "$DEST_DIR"
cp sapi/cli/php "$DEST"
chmod 755 "$DEST"

echo
echo "=== PHP statique installe: $DEST ==="
file "$DEST"
ls -lh "$DEST"
"$DEST" -v

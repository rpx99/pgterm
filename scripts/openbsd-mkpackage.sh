#!/bin/sh
#
# Baut das OpenBSD-Paket pgterm-X.Y.Z.tgz aus dem lokalen Repo-Stand -
# komplett OHNE root (alles landet unter ~/.pgterm-ports und openbsd-port/
# im Repo). Nur die optionale Installation mit pkg_add braucht doas.
#
# Aufruf:
#   ./scripts/openbsd-mkpackage.sh --check    # neuer Stand auf origin/upstream?
#   ./scripts/openbsd-mkpackage.sh            # nur bauen
#   ./scripts/openbsd-mkpackage.sh -i         # bauen + installieren
#   ./scripts/openbsd-mkpackage.sh -p         # bauen + committen + pushen
#   ./scripts/openbsd-mkpackage.sh -ip        # alles zusammen
#   ./scripts/openbsd-mkpackage.sh -i 0.1.2   # Version explizit vorgeben
#
# Ueberschreibbar per Env: PGTERM_PORTS_BASE, DISTDIR, WRKOBJDIR,
# PACKAGE_REPOSITORY (oder historisch PACKAGES), PLIST_REPOSITORY, PORTTREE,
# PORTSDIR, MAINTAINER, FORK_URL, UPSTREAM_URL, DRY_RUN=1
set -eu

DRY=${DRY_RUN:-0}
INSTALL_AFTER=0
PUSH_AFTER=0
FORK_URL=${FORK_URL:-}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/pgrundev/pgterm.git}

run() {
	if [ "$DRY" = 1 ]; then echo "[dry] $*"; else "$@"; fi
}

usage() {
	cat <<EOF
usage: $(basename "$0") [-h] [--check] [-i] [-p] [-ip] [VERSION]

Baut pgterm-VERSION.tgz aus dem lokalen Repo-Stand - ohne root.
Nur die optionale Installation mit pkg_add braucht doas.

Optionen:
  -h, --help   diese Hilfe
  --check      neuen Stand auf origin/upstream pruefen
  -i           nach dem Bau mit pkg_add installieren
  -p           nach dem Bau committen und pushen
  -ip, -pi     -i und -p zusammen
  VERSION      z.B. 0.1.2 (sonst aus Cargo.toml)

Umgebung:
  DRY_RUN=1              nur anzeigen, nichts schreiben
  REVISION=0             Ports-REVISION (Paket 0.1.2p0). Leer = erste
                         Ausgabe dieser Cargo-Version. Ungesetzt = auto
                         (naechstes pN wenn Tag vVERSION-openbsd existiert)
  PGTERM_PORTS_BASE      Default: ~/.pgterm-ports
  DISTDIR, WRKOBJDIR, PACKAGE_REPOSITORY, PLIST_REPOSITORY
  PORTTREE, PORTSDIR, MAINTAINER, FORK_URL, UPSTREAM_URL

Beispiele:
  $0                 nur bauen
  $0 -i              bauen und installieren
  $0 --check
  $0 -i 0.1.2
EOF
}

ver_of() {
	awk '/^version/ {gsub(/"/, "", $3); print $3; exit}' "$1"
}

is_upstream_url() {
	case "$1" in
	*github.com/pgrundev/pgterm*) return 0 ;;
	*) return 1 ;;
	esac
}

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
	|| { echo "FEHLER: nicht in einem Git-Repository"; exit 1; }

if [ -z "${MAINTAINER:-}" ]; then
	_n=$(git -C "$REPO" config --get user.name 2>/dev/null || true)
	_e=$(git -C "$REPO" config --get user.email 2>/dev/null || true)
	if [ -n "$_n" ] && [ -n "$_e" ]; then
		MAINTAINER="$_n <$_e>"
	else
		MAINTAINER="Your Name <you@example.invalid>"
	fi
fi

BASE=${PGTERM_PORTS_BASE:-$HOME/.pgterm-ports}
DISTDIR=${DISTDIR:-$BASE/distfiles}
WRKOBJDIR=${WRKOBJDIR:-$BASE/wrk}
PACKAGE_REPOSITORY=${PACKAGE_REPOSITORY:-${PACKAGES:-$BASE/packages}}
PLIST_REPOSITORY=${PLIST_REPOSITORY:-$BASE/plist}
PORTSDIR=${PORTSDIR:-/usr/ports}
# User-eigener Ports-Baum im "mystuff"-Stil: <tree>/databases/pgterm,
# wird per PORTSDIR_PATH vor /usr/ports durchsucht.
PORTTREE=${PORTTREE:-$REPO/openbsd-port}

MODE=build
V_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help)	usage; exit 0 ;;
	--check)	MODE=check ;;
	-i)		INSTALL_AFTER=1 ;;
	-p)		PUSH_AFTER=1 ;;
	-ip|-pi)	INSTALL_AFTER=1; PUSH_AFTER=1 ;;
	-.*)		echo "FEHLER: unbekannte Option '$1'" >&2; usage >&2; exit 1 ;;
	-*)		echo "FEHLER: unbekannte Option '$1'" >&2; usage >&2; exit 1 ;;
	*)		V_OVERRIDE=$1 ;;
	esac
	shift
done

V=${V_OVERRIDE:-$(ver_of "$REPO/Cargo.toml")}
[ -n "$V" ] || { echo "FEHLER: Version nicht ermittelbar (Parameter angeben)"; exit 1; }

# Same Cargo version, new OpenBSD rebuild: REVISION (0.1.2 -> 0.1.2p0).
# Tag vX.Y.Z-openbsd is the first package; vX.Y.Z-openbsd.1 is p0, .2 is p1.
PKG_REVISION=""
if [ "${REVISION+x}" = x ]; then
	PKG_REVISION=$REVISION
else
	git -C "$REPO" fetch origin --tags >/dev/null 2>&1 || true
	if git -C "$REPO" rev-parse -q --verify "refs/tags/v${V}-openbsd" >/dev/null 2>&1; then
		n=0
		while git -C "$REPO" rev-parse -q --verify "refs/tags/v${V}-openbsd.$((n + 1))" >/dev/null 2>&1; do
			n=$((n + 1))
		done
		PKG_REVISION=$n
	fi
fi
if [ -z "$PKG_REVISION" ]; then
	FULLPKG="pgterm-$V"
	GH_TAG="v${V}-openbsd"
else
	FULLPKG="pgterm-${V}p${PKG_REVISION}"
	GH_TAG="v${V}-openbsd.$((PKG_REVISION + 1))"
fi

if [ "$MODE" = check ]; then
	# origin darf der Fork sein. Neue Releases liegen auf pgrundev/pgterm.
	SYNC_REMOTE=origin
	if ORIGIN_URL=$(git -C "$REPO" remote get-url origin 2>/dev/null); then
		if ! is_upstream_url "$ORIGIN_URL"; then
			if git -C "$REPO" remote get-url upstream >/dev/null 2>&1; then
				SYNC_REMOTE=upstream
			else
				git -C "$REPO" remote add upstream "$UPSTREAM_URL"
				SYNC_REMOTE=upstream
			fi
		fi
	else
		git -C "$REPO" remote add upstream "$UPSTREAM_URL"
		SYNC_REMOTE=upstream
	fi
	git -C "$REPO" fetch "$SYNC_REMOTE" main >/dev/null 2>&1 \
		|| { echo "FEHLER: git fetch $SYNC_REMOTE fehlgeschlagen (Netz?)"; exit 1; }
	CARGO=Cargo.toml
	LV=$(ver_of "$REPO/$CARGO")
	RV=$(git -C "$REPO" show "$SYNC_REMOTE/main:$CARGO" \
		| awk '/^version/ {gsub(/"/, "", $3); print $3; exit}')
	UP_SHA=$(git -C "$REPO" rev-parse "$SYNC_REMOTE/main")
	BASE_SHA=$(git -C "$REPO" merge-base HEAD "$SYNC_REMOTE/main")
	echo "lokal    : $LV ($(git -C "$REPO" rev-parse --short HEAD))"
	echo "$SYNC_REMOTE/main : $RV ($(git -C "$REPO" rev-parse --short "$SYNC_REMOTE/main"))"
	if [ "$SYNC_REMOTE" != origin ]; then
		O=$(git -C "$REPO" rev-parse --short origin/main 2>/dev/null || true)
		if [ -n "$O" ]; then
			echo "Fork     : $O (origin, nicht die Sync-Quelle)"
		fi
	fi
	if [ "$UP_SHA" = "$BASE_SHA" ]; then
		echo "==> kein neuer Stand: $SYNC_REMOTE/main steckt bereits in HEAD."
	else
		N=$(git -C "$REPO" rev-list --count "$BASE_SHA".."$UP_SHA")
		echo "==> $N neuer Commit(s) auf $SYNC_REMOTE/main (nicht in HEAD):"
		git -C "$REPO" --no-pager log --oneline -15 "$BASE_SHA".."$UP_SHA"
		if [ "$N" -gt 15 ]; then
			echo "    ... ($N insgesamt)"
		fi
		if [ "$LV" = "$RV" ]; then
			echo "==> Cargo-Version bleibt $RV"
		else
			echo "==> Cargo-Version $LV -> $RV"
		fi
		echo "Dann:"
		echo "    git fetch $SYNC_REMOTE && git rebase $SYNC_REMOTE/main"
		echo "    $0"
	fi
	exit 0
fi

for tool in git rustc cargo make awk grep pax; do
	command -v "$tool" >/dev/null || { echo "FEHLER: '$tool' fehlt"; exit 1; }
done
[ -d "$PORTSDIR" ] || { echo "FEHLER: $PORTSDIR existiert nicht (ports(7))"; exit 1; }

echo "==> Version: $V${PKG_REVISION:+p$PKG_REVISION}  (GitHub-Tag $GH_TAG)"
echo "==> Verzeichnisse: PORTTREE=$PORTTREE DISTDIR=$DISTDIR"

# 1. Quell-Tarball aus dem lokalen Stand (inkl. uncommitteter Aenderungen;
#    Kern-Dumps und Paket-Metadaten-Reste ausschliessen)
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT INT TERM
(cd "$REPO" && git ls-files -co --exclude-standard \
	| grep -vE '(^|/)([^/]*\.core|core|\+[^/]*)$' \
	| while IFS= read -r file; do
		if [ -e "$file" ] || [ -L "$file" ]; then
			printf '%s\n' "$file"
		fi
	done) >"$LIST"

if [ "$DRY" = 1 ]; then
	echo "[dry] pax -w -z -f $DISTDIR/pgterm-$V.tar.gz  (< Dateiliste, Prefix pgterm-$V/)"
	echo "[dry] Port-Skelett unter $PORTTREE/databases/pgterm erzeugen"
	echo "[dry] modcargo-gen-crates, makesum und package ausfuehren"
	exit 0
fi

# Alte Build-Reste wegwerfen: Extraktion muss IMMER dem aktuellen Tarball
# entsprechen (Cookie-Timestamps truegen sonst bei geaendertem Inhalt).
rm -rf "${WRKOBJDIR:?}/pgterm-$V"

mkdir -p "$DISTDIR"
(cd "$REPO" && pax -w -z -x ustar -s ",^,pgterm-$V/," -f "$DISTDIR/pgterm-$V.tar.gz" <"$LIST")

# 2. Port-Skelett schreiben (im Repo, user-eigen, Kategorie-Layout)
PORTDIR="$PORTTREE/databases/pgterm"
mkdir -p "$PORTDIR/pkg"

REVISION_LINE=""
if [ -n "$PKG_REVISION" ]; then
	REVISION_LINE="REVISION =	$PKG_REVISION"
fi

cat >"$PORTDIR/Makefile" <<EOF
COMMENT =	htop for all your Postgres databases
V =		$V
$REVISION_LINE
DISTNAME =	pgterm-\${V}
DISTFILES =	\${DISTNAME}\${EXTRACT_SUFX}
PKGNAME =	pgterm-\${V}
CATEGORIES =	databases
HOMEPAGE =	https://pgterm.dev
MAINTAINER =	$MAINTAINER

# Apache-2.0
PERMIT_PACKAGE =	Yes

WANTLIB +=	\${MODCARGO_WANTLIB} m

MODULES =	devel/cargo
CONFIGURE_STYLE =	cargo
.include "crates.inc"

.include <bsd.port.mk>
EOF

cat >"$PORTDIR/pkg/DESCR" <<'EOF'
pgterm is an interactive terminal UI that monitors every PostgreSQL
database you care about in one place. Each tab is one database; pgterm
checks them in the background and flags the tab that needs attention.

It drives pgbot (https://pgbot.dev) as a read-only diagnostic engine.
Install pgbot separately and keep it on PATH, or set PGBOT_BIN.

Configuration lives in ~/.config/pgterm/config.toml and stores
environment-variable names, never connection strings.

Native OpenBSD source build of https://github.com/pgrundev/pgterm.
EOF

cat >"$PORTDIR/pkg/PLIST" <<'EOF'
@comment \$OpenBSD\$
@bin bin/pgterm
EOF

: >"$PORTDIR/crates.inc"
# distinfo ebenfalls wegwerfen: es referenziert die alten Cargo-Eintraege,
# die die (noch leere) Liste bei NO_CHECKSUM als "Extra file" meldet.
rm -f "$PORTDIR/distinfo"

# 3. Port-Mechanik - alle Schreibpfade liegen beim Nutzer, kein root noetig.
#    Variablen als MAKE-ARGUMENTE: Kommandozeile schlaegt auch /etc/mk.conf.
MKVARS="PORTSDIR=$PORTSDIR PORTSDIR_PATH=$PORTTREE:$PORTSDIR:$PORTSDIR/mystuff WRKOBJDIR=$WRKOBJDIR LOCKDIR=$BASE/locks DISTDIR=$DISTDIR PACKAGE_REPOSITORY=$PACKAGE_REPOSITORY PLIST_REPOSITORY=$PLIST_REPOSITORY"
mkdir -p "$BASE/locks" "$PLIST_REPOSITORY"

# 3b. Crate-Liste aus Cargo.lock generieren (erster Lauf ohne Checksummen),
#     dann laedt makesum alle Crates und schreibt die Pruefsummen.
cd "$PORTDIR"
make $MKVARS modcargo-gen-crates NO_CHECKSUM=Yes >"$LIST"
grep '^MODCARGO_CRATES' "$LIST" >"$PORTDIR/crates.inc"
[ -s "$PORTDIR/crates.inc" ] \
	|| { echo "FEHLER: keine Crates in Cargo.lock erkannt"; exit 1; }
echo "==> crates.inc: $(grep -c . "$PORTDIR/crates.inc") Crates"
run make $MKVARS makesum
echo "==> distinfo: $(grep -c 'SHA256' "$PORTDIR/distinfo" 2>/dev/null || echo 0) Checksummen"
# Crates sind jetzt komplett da -> Workdir verwerfen, damit das folgende
# 'package' sie frisch extrahiert (sonst leert der alte Cookie den Vendor-Dir).
# Das vorhandene .tgz IST der Ports-Cookie (_PACKAGE_COOKIE): ohne Loeschen
# macht 'make package' nur "Link to .../ftp/..." und baut nicht neu.
rm -rf "${WRKOBJDIR:?}/pgterm-$V"
if [ -d "$PACKAGE_REPOSITORY" ]; then
	find "$PACKAGE_REPOSITORY" -name "$FULLPKG.tgz" -print -delete
fi
run make $MKVARS package

PKG=""
for f in "$PACKAGE_REPOSITORY"/*/all/"$FULLPKG".tgz; do
	if [ -f "$f" ]; then
		PKG=$f
		break
	fi
done
if [ -z "$PKG" ]; then
	echo "FEHLER: fertiges Paket nicht gefunden (make-Ausgabe oben pruefen)"; exit 1
fi

echo "==> Paket: $PKG"
echo "==> GitHub-Tag: $GH_TAG"

# 4. Optional: Stand committen und pushen
if [ "$PUSH_AFTER" = 1 ]; then
	cd "$REPO"
	if ORIGIN_URL=$(git remote get-url origin 2>/dev/null); then
		case "$ORIGIN_URL" in
		*github.com/pgrundev/pgterm*)
			# origin ist upstream. Nur auf einen Fork pushen, wenn
			# FORK_URL gesetzt ist oder bereits ein Fork-origin existiert.
			if [ -n "$FORK_URL" ] && ! is_upstream_url "$FORK_URL"; then
				if git remote get-url upstream >/dev/null 2>&1; then
					git remote set-url origin "$FORK_URL"
				else
					git remote rename origin upstream
					git remote add origin "$FORK_URL"
				fi
			fi
			;;
		esac
	else
		[ -n "$FORK_URL" ] || {
			echo "FEHLER: kein origin; FORK_URL setzen." >&2
			exit 1
		}
		git remote add origin "$FORK_URL"
	fi
	git remote get-url upstream >/dev/null 2>&1 \
		|| git remote add upstream "$UPSTREAM_URL"

	if ! git diff --quiet HEAD || ! git diff --cached --quiet HEAD \
		|| [ -n "$(git ls-files --others --exclude-standard | grep -vE '(^|/)([^/]*\.core|core|\+[^/]*)$')" ]; then
		git add -A -- . ':(exclude)*.core' ':(exclude)+*' 2>/dev/null || git add -A
		git commit -m "OpenBSD port support (pgterm $V)

- scripts/openbsd-mkpackage.sh: ports(7)-Paket ohne root
- openbsd-port/databases/pgterm Skeleton"
	else
		echo "==> Keine Aenderungen zu committen."
	fi
	PUSH_URL=$(git remote get-url origin)
	echo "==> Push auf $PUSH_URL ..."
	if ! git push origin HEAD; then
		echo "HINWEIS: Push fehlgeschlagen. Fork anlegen und als origin konfigurieren:" >&2
		echo "  git remote set-url origin <URL-DES-EIGENEN-FORKS>" >&2
	fi
fi

# 5. Optional installieren - pkg_add ist Systemverwaltung und braucht doas.
#    -u interpretiert Argumente als installierte PaketNAMEN, nicht als
#    Dateipfad. -r ersetzt das vorhandene Paket, -D unsigned erlaubt das
#    unsignierte Lokal-tgz.
if [ "$INSTALL_AFTER" = 1 ]; then
	if [ "$(id -u)" = 0 ]; then
		pkg_add -r -D unsigned -D updatedepends "$PKG"
	else
		if command -v doas >/dev/null 2>&1; then
			doas pkg_add -r -D unsigned -D updatedepends "$PKG"
		else
			sudo pkg_add -r -D unsigned -D updatedepends "$PKG"
		fi
	fi
else
	echo "==> Installieren (nicht -u mit Dateipfad!):"
	echo "    doas pkg_add -r -D unsigned -D updatedepends $PKG"
fi

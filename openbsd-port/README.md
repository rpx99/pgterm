# pgterm auf OpenBSD

Offizielle GitHub-Releases sind nur linux/macOS. Auf OpenBSD baut man
aus dem Quelltext: `cargo build --release` reicht fuer eine lokale
Binary. Dieses Verzeichnis plus `scripts/openbsd-mkpackage.sh` erzeugt
zusaetzlich ein `pkg_add`-Paket im ports(7)-Rahmen, analog zu grok-build.

## Ohne Paket (schnell)

```sh
cargo build --release          # -> target/release/pgterm
cargo test --locked
```

pgterm braucht [pgbot](https://pgbot.dev) zur Laufzeit (`PATH` oder
`PGBOT_BIN`). pgbot ist kein Teil dieses Ports.

Keine Source-Aenderungen noetig: Abhaengigkeiten (tokio/mio/crossterm/
ratatui/dirs) sind Unix/`kqueue` und laufen auf OpenBSD. `#[cfg(unix)]`
greift hier. Der Installer `install.sh` liefert keine OpenBSD-Binary
(keine Release-Assets) und verweist auf den Source-Build.

## Paket bauen

Das Skript baut immer den aktuellen lokalen Stand. Es synchronisiert den
Branch nicht automatisch.

```sh
DRY_RUN=1 ./scripts/openbsd-mkpackage.sh  # Ablauf ohne Paketbau pruefen
./scripts/openbsd-mkpackage.sh            # nur bauen
./scripts/openbsd-mkpackage.sh -i         # bauen und installieren
./scripts/openbsd-mkpackage.sh -p         # bauen, committen und pushen
./scripts/openbsd-mkpackage.sh -ip        # bauen, installieren und pushen
```

Nur die Installation mit `pkg_add` benoetigt `doas`. Build-Dateien und
Pakete landen standardmaessig unter `$HOME/.pgterm-ports`; der Port selbst
liegt unter `openbsd-port/databases/pgterm`. Die Pfade lassen sich unter
anderem mit `PGTERM_PORTS_BASE`, `DISTDIR`, `WRKOBJDIR`,
`PACKAGE_REPOSITORY`, `PORTTREE` und `PORTSDIR` ueberschreiben. Eine
vollstaendige Liste zeigt:

```sh
./scripts/openbsd-mkpackage.sh --help
```

## Remotes

Die erwartete Zuordnung ist:

- `origin`: der eigene Fork `https://github.com/rpx99/pgterm.git`
- `upstream`: `https://github.com/pgrundev/pgterm.git`

Vor dem ersten Release die Zuordnung kontrollieren:

```sh
git remote -v
```

Fehlt `upstream`, kann er explizit ergaenzt werden. `--check` erledigt dies
ebenfalls automatisch:

```sh
git remote add upstream https://github.com/pgrundev/pgterm.git
```

Wenn kein `origin` vorhanden ist, kann dessen URL vor einem Push gesetzt werden:

```sh
git remote add origin git@github.com:rpx99/pgterm.git
```

Alternativ akzeptiert das Paket-Skript `FORK_URL` und `UPSTREAM_URL` als
Umgebungsvariablen. `FORK_URL` muss nicht bei jedem Aufruf angegeben werden:
Wenn `origin` bereits auf den eigenen Fork zeigt, verwendet das Skript diese
gespeicherte URL automatisch.

`--check` holt den Stand von `upstream/main` (nicht den Fork) und zeigt, ob
neue Commits vorhanden sind. Es veraendert den lokalen Branch nicht.

```sh
./scripts/openbsd-mkpackage.sh --check
```

Vor einem Rebase muss der Arbeitsbaum sauber sein:

```sh
git fetch upstream
git rebase upstream/main
```

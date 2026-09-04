COMMENT =	htop for all your Postgres databases
V =		0.1.2

DISTNAME =	pgterm-${V}
DISTFILES =	${DISTNAME}${EXTRACT_SUFX}
PKGNAME =	pgterm-${V}
CATEGORIES =	databases
HOMEPAGE =	https://pgterm.dev
MAINTAINER =	Robert Palm <developer@robert-palm.de>

# Apache-2.0
PERMIT_PACKAGE =	Yes

WANTLIB +=	${MODCARGO_WANTLIB} m

MODULES =	devel/cargo
CONFIGURE_STYLE =	cargo
.include "crates.inc"

.include <bsd.port.mk>

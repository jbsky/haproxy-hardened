# syntax=docker/dockerfile:1
# =====================================================================
#  haproxy-hardened -- HAProxy FROM scratch
#
#  HAProxy (le service expose) compile depuis les sources, archive verifiee
#  par son sha256 (l'amont publie un .sha256, pas de signature) ; OpenSSL,
#  PCRE2 et musl restent des paquets Alpine (regle du parc : « aucun apk »
#  vise le service expose, pas ses bibliotheques).
#
#  Options : celles d'Alpine (APKBUILD 3.4.6, aucun patch) MOINS ce que la
#  configuration cible n'utilise pas -- ni Lua, ni QUIC, ni namespaces (actifs
#  par defaut sur la cible linux : USE_NS= explicite), ni
#  exporteur Prometheus, ni zlib (la compression passe par SLZ, integre).
#  Moins de code expose, et des bibliotheques de moins dans la cloture.
#
#  Aucune version n'est ecrite ici : versions.json est la seule source
#  (scripts/versions-build-args.py, verifie au job lint).
# =====================================================================

# ---------------------------------------------------------------------
#  builder : telechargement verifie + compilation durcie
# ---------------------------------------------------------------------
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS builder
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG HAPROXY_VERSION
ARG HAPROXY_SHA256
# Echouer tout de suite, avec la marche a suivre, plutot que construire a vide.
RUN test -n "${HAPROXY_VERSION}" -a -n "${HAPROXY_SHA256}" \
    || { echo "build-args requis depuis versions.json : make build, ou docker build \$(scripts/versions-build-args.py --docker) ." >&2; exit 1; }

# Derriere un proxy qui dechiffre le TLS : CA en secret BuildKit, jamais en couche.
RUN --mount=type=secret,id=ca-certs,target=/tmp/ca-bundle.crt,required=false \
    if [ -f /tmp/ca-bundle.crt ]; then \
      cat /tmp/ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi

RUN apk upgrade --no-cache \
 && apk add --no-cache curl file gcc linux-headers make musl-dev openssl-dev pcre2-dev

# Telechargement et verification dans le MEME RUN ; sha256 compare depuis un
# fichier, jamais par un pipe (qui reussit sur un flux vide).
RUN branche="${HAPROXY_VERSION%.*}" \
 && curl -fsSL "https://www.haproxy.org/download/${branche}/src/haproxy-${HAPROXY_VERSION}.tar.gz" -o /tmp/haproxy.tar.gz \
 && printf '%s  /tmp/haproxy.tar.gz\n' "${HAPROXY_SHA256}" > /tmp/haproxy.sha256 \
 && sha256sum -c /tmp/haproxy.sha256 \
 && mkdir -p /usr/src \
 && tar -xzf /tmp/haproxy.tar.gz -C /usr/src \
 && rm -f /tmp/haproxy.tar.gz /tmp/haproxy.sha256

# ADDINC/ADDLIB s'AJOUTENT aux options du Makefile amont (qui portent
# -O2, -fwrapv...) au lieu de les remplacer, comme le ferait CFLAGS.
# ARCH_FLAGS vide : le defaut amont est -g, inutile puisqu'on strippe.
RUN cd "/usr/src/haproxy-${HAPROXY_VERSION}" \
 && make -j"$(nproc)" \
      TARGET=linux-musl \
      USE_OPENSSL=1 \
      USE_PCRE2=1 \
      USE_PCRE2_JIT=1 \
      USE_NS= \
      ARCH_FLAGS= \
      ADDINC="-fPIE -fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
      ADDLIB="-pie -Wl,-z,relro,-z,now,-z,noexecstack" \
 && make install-bin DESTDIR=/out PREFIX=/usr \
 && ./haproxy -vv | sed -n '1p;/^Feature list/,/^$/p'

# Strip par liste d'ELF : jamais `find -exec strip` (code retour avale),
# jamais `|| true`.
RUN find /out -type f \( -name '*.so*' -o -perm -111 \) > /tmp/cand.list \
 && : > /tmp/elf.list \
 && while IFS= read -r f; do \
      case "$(file -b "$f")" in *ELF*) echo "$f" >> /tmp/elf.list ;; esac; \
    done < /tmp/cand.list \
 && test -s /tmp/elf.list \
 && xargs -r strip --strip-unneeded < /tmp/elf.list \
 && echo "haproxy=${HAPROXY_VERSION}" > /out/image-versions

# ---------------------------------------------------------------------
#  gobuilder : init statique (entrypoint, healthcheck, setup-dirs)
# ---------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS gobuilder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /build
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -ldflags='-s -w' -trimpath -o /init .

# ---------------------------------------------------------------------
#  prep : arborescence runtime + cloture de dependances
#  Le gabarit build-push construit et scanne ce stage a part (Trivy, SBOM).
# ---------------------------------------------------------------------
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS prep
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
# apk upgrade d'abord : `apk add` ne met jamais a jour un paquet deja dans la
# base (libcrypto3, musl...).
RUN apk upgrade --no-cache \
 && apk add --no-cache ca-certificates libssl3 libcrypto3 pcre2 tzdata tini-static

RUN addgroup -g 4430 -S haproxy \
 && adduser -S -D -H -u 4430 -h /var/lib/haproxy -s /sbin/nologin -G haproxy haproxy

COPY --from=builder /out/usr/sbin/haproxy /usr/sbin/haproxy
COPY --from=builder /out/image-versions /etc/image-versions
COPY --chown=root:haproxy conf/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg

# Cloture resolue au build : le garde « Not found » porte sur la liste NON
# filtree ; le filtre retire ensuite la racine, deja copiee par son propre
# COPY dans le stage final (sinon elle part deux fois).
RUN apk add --no-cache lddtree \
 && mkdir -p /rootfs \
 && lddtree -l /usr/sbin/haproxy > /tmp/closure.list 2> /tmp/closure.err \
 && if grep -q 'Not found' /tmp/closure.list /tmp/closure.err; then \
      echo "cloture incomplete -- une dependance manque a ce stage :" >&2; \
      grep 'Not found' /tmp/closure.list /tmp/closure.err >&2; \
      exit 1; \
    fi \
 && sort -u /tmp/closure.list -o /tmp/closure.list \
 && grep -v -E '^/usr/sbin/haproxy$' /tmp/closure.list > /tmp/closure.deps \
 && tar -cf /tmp/closure.tar -T /tmp/closure.deps \
 && tar -xf /tmp/closure.tar -C /rootfs \
 && rm -f /tmp/closure.list /tmp/closure.deps /tmp/closure.err /tmp/closure.tar

# Pas de /usr/lib/ossl-modules : il ne contient que legacy.so, le provider
# des algorithmes retires (MD4, RC4, DES...). Le provider par defaut est dans
# libcrypto ; embarquer legacy n'ajouterait que de la surface.

FROM prep AS prep-clean
RUN rm -rf /lib/apk /lib/libapk* /var/cache/apk /etc/apk /sbin/apk

# ---------------------------------------------------------------------
#  image finale
# ---------------------------------------------------------------------
FROM scratch
LABEL org.opencontainers.image.title="haproxy-hardened" \
      org.opencontainers.image.description="HAProxy FROM scratch -- compiled from source, non-root, zero shell" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.licenses="GPL-2.0-or-later AND Apache-2.0" \
      org.opencontainers.image.source="https://github.com/jbsky/haproxy-hardened" \
      security.hardening.tier="platine" \
      security.hardening.features="from-scratch,go-init,tini-pid1,zero-shell,non-root,compiler-hardening,cosign-signed,sbom,slsa-provenance"

COPY --link --from=prep-clean /etc/passwd /etc/passwd
COPY --link --from=prep-clean /etc/group  /etc/group
COPY --link --from=prep-clean /rootfs/ /
COPY --link --from=prep-clean /usr/sbin/haproxy /usr/sbin/haproxy
COPY --link --from=prep-clean /usr/local/etc/haproxy/ /usr/local/etc/haproxy/
COPY --link --from=prep-clean /etc/image-versions /etc/image-versions
COPY --link --from=prep-clean /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --link --from=prep-clean /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf
COPY --link --from=prep-clean /usr/share/zoneinfo/ /usr/share/zoneinfo/
COPY --link --from=prep-clean /sbin/tini-static /sbin/tini
COPY --link --from=gobuilder /init /usr/local/bin/init

RUN ["/usr/local/bin/init", "--setup-dirs"]

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER 4430:4430
EXPOSE 8080 8443
# SIGUSR1 = arret doux de HAProxy (les connexions en cours se terminent).
STOPSIGNAL SIGUSR1
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/init"]
CMD ["haproxy", "-W", "-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]

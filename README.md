# HAProxy Hardened

HAProxy compile depuis les sources, dans une image `FROM scratch` : ni shell, ni
gestionnaire de paquets, ni OS. Uniquement HAProxy, ses bibliotheques (OpenSSL,
PCRE2, musl), `tini` et un init Go statique.

## Ce qui est compile

Les options du paquet Alpine (aucun patch), **moins** ce qu'une configuration de
reverse-proxy TLS n'utilise pas :

| Option | Etat | Pourquoi |
|---|---|---|
| OpenSSL | oui | terminaison TLS |
| PCRE2 + JIT | oui | ACL a expressions regulieres |
| SLZ | oui | compression, integree a HAProxy (pas de zlib) |
| Lua, QUIC, namespaces, exporteur Prometheus, zlib | **non** | moins de code expose, moins de bibliotheques |
| provider OpenSSL `legacy` | **non** | algorithmes retires (MD4, RC4, DES...) |

Une option manque ? Elle s'ajoute dans le `make` du `Dockerfile`, avec sa
bibliotheque dans le stage `prep` ; la cloture de dependances suit seule.

## Hardening

- `FROM scratch`, utilisateur non-root `4430:4430`, aucune capacite par defaut.
- Compilation : PIE, RELRO complet, `-fstack-protector-strong`,
  `-fstack-clash-protection`, `_FORTIFY_SOURCE=2`, pile non executable ; binaire
  strippe.
- Archive amont verifiee par son sha256 (`versions.json`), dans le meme `RUN`
  que son telechargement.
- Bibliotheques copiees depuis une cloture resolue au build (`lddtree`), jamais
  `/lib` ou `/usr/lib` en bloc.
- L'init valide la configuration (`haproxy -c`) **avant** de demarrer : une
  configuration cassee empeche le demarrage.
- Fonctionne avec un rootfs en lecture seule (tmpfs sur `/tmp` et `/run/haproxy`).

## Tags

Trois tags par image : `latest` (dernier build de `main`), la version amont
seule, et la version amont suffixee d'un **compteur de revision**. Les deux
premiers sont **reecrits en place** a chaque rebuild. **En production, epinglez
le tag qui porte le compteur.**

<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->
| Image | Version amont | Tag immuable a epingler |
|-------|---------------|-------------------------|
| `jbsky/haproxy-hardened` | `3.4.6` | `3.4.6.2` |
<!-- END:tags -->

Le compteur compte les commits qui touchent les entrees de l'image
(`Dockerfile`, `conf/`, `init.go`, `go.mod`, `versions.json`) et repart a zero a
chaque nouvelle version d'HAProxy. `docker.io` et `ghcr.io` publient les memes
tags avec le meme digest.

## Usage

```bash
docker run -d --name haproxy \
  --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:mode=1777 --tmpfs /run/haproxy:mode=0750,uid=4430,gid=4430 \
  -v ./haproxy:/usr/local/etc/haproxy:ro \
  -p 80:80 -p 443:443 \
  jbsky/haproxy-hardened:latest
```

- La configuration se monte sur `/usr/local/etc/haproxy/` ; l'image en livre une
  minimale (port 8080, healthcheck) pour tester.
- Les arguments peuvent etre passes sans le nom du binaire (`-W -f ...`) : l'init
  ajoute `haproxy` devant.
- Healthcheck : `GET http://127.0.0.1:8405/healthz` (un `monitor-uri` a prevoir
  dans votre configuration, ou une autre URL via `HAPROXY_HEALTH_URL`).
- Les fichiers montes (certificats compris) doivent etre lisibles par l'uid
  `4430` : `chgrp 4430` + `chmod 640` sur les cles plutot qu'un `644`.

## Security & Verification

Image signee par [cosign](https://github.com/sigstore/cosign) (keyless OIDC).

```bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/(jbsky/haproxy-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/haproxy-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/jbsky/haproxy-hardened:latest

COSIGN_REPOSITORY=ghcr.io/jbsky/haproxy-hardened \
  cosign verify \
  --certificate-identity-regexp '^https://github.com/(jbsky/haproxy-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/haproxy-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/jbsky/haproxy-hardened:latest
```

La chaine de CI vient de [jbsky/hardened-ci](https://github.com/jbsky/hardened-ci) :
lint, build, scan CVE du stage `prep`, tests sur le digest exact (manifeste
d'image, cloture, `scripts/test.sh`), signature, SBOM attestee, audit hebdomadaire.

## License

Le contenu de ce depot -- Dockerfile, `init.go`, scripts et chaine CI -- est sous
**Apache-2.0**, voir [`LICENSE`](LICENSE). Copyright 2026 jbsky.

HAProxy garde sa licence, **GPL-2.0-or-later** (avec exception OpenSSL). `init.go`
est un programme distinct, qui execute HAProxy sans etre lie a lui.

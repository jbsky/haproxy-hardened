# Security Audit Status

Le workflow hebdomadaire `security-audit.yml` (Trivy + Grype) scanne l'image
publiee, et `cve-watch.yml` relit chaque jour la SBOM du stage `prep` : une CVE
corrigeable ouvre une issue `cve`.

Aucune exception n'est suivie a ce jour. Toute exception future se documente ici
(CVE, paquet, pourquoi, quand elle se leve) avant d'etre ajoutee a `.grype.yaml`.

Signaler une vulnerabilite de l'image : ouvrir une issue privee (security
advisory) sur ce depot.

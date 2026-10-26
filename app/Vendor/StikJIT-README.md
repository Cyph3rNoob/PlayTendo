# StikJIT fourni avec PlayTendo

PlayTendo embarque le XCFramework officiel StikJIT 1.9.0 dans `StikJIT.xcframework`.

- Code source et instructions d'intégration : [StikDebug/StikJIT, version 1.9.0](https://github.com/StikDebug/StikJIT/tree/1.9.0)
- Licence : [Mozilla Public License 2.0](StikJIT-LICENSE)

L'application utilise StikJIT depuis une extension d'aide classique embarquée dans `PlugIns`. PlayTendo la lance
par son identifiant installé afin de rester compatible avec le suffixe ajouté par les outils de sideloading. La
requête d'extension transporte le jumelage et les paramètres en mémoire. Le framework StikJIT est fourni sans
modification; son code source est disponible au lien ci-dessus.

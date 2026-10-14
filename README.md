# PABX Asterisk de test

Petit PABX [Asterisk](https://www.asterisk.org/) 22 LTS en conteneur, pour
tester des softphones, un trunk SIP opérateur et, surtout, la musique de
prédécroché en early media (`183 Session Progress`).

- 3 postes : `100`, `101`, `102`
- 1 trunk SIP optionnel, enregistré chez l'opérateur
- services de test : `600` écho, `601` hello world, `602` musique d'attente,
  `603` horloge parlante, `604` musique de prédécroché
- musique de prédécroché optionnelle sur les appels entrants
- capture continue du SIP et du RTP, téléchargeable depuis une petite
  interface web
- banc de test [SIPp](https://sipp.sourceforge.net/) du 183, sans opérateur ni
  softphone

Asterisk 22.11.0 est compilé depuis les sources (Debian trixie). Par défaut,
tout n'est joignable que depuis la machine hôte (`127.0.0.1`). C'est un outil
de test : ne pas l'exposer sur Internet.

## Prérequis

`make` et [Podman](https://podman.io/) avec `podman compose`, ou Docker avec
`docker compose` (`make CTR=docker ...`).

## Démarrage

```bash
make init       # crée .env, construit les images, démarre le PABX
make accounts   # serveur et identifiants des postes
make endpoints  # état des postes
```

La première construction compile Asterisk : compter une dizaine de minutes.

`make init` crée `.env` (non versionné) à partir de
[`.env.example`](.env.example), avec des mots de passe aléatoires pour les
postes. La configuration ([`config/`](config)) est copiée dans `/etc/asterisk`
à chaque démarrage, en remplaçant les `@VARIABLE@` par les valeurs de `.env`.
Après une modification de l'un ou de l'autre :

```bash
make reset
```

## Softphones

| Paramètre       | Valeur                        |
| --------------- | ----------------------------- |
| Serveur/domaine | `127.0.0.1`, port 5060        |
| Utilisateur     | `100`, `101` ou `102`         |
| Mot de passe    | `SIP_PASSWORD_1xx` de `.env`  |
| Transport       | UDP ou TCP                    |

Les postes peuvent proposer du SRTP (SDES), il est accepté sans être exigé.

### Accès depuis le réseau local

Dans `.env`, puis `make reset` :

```bash
PBX_EXTERNAL_IP=192.0.2.10   # IP LAN de l'hôte, voir: make -s host_ip
PBX_BIND=0.0.0.0             # publie les ports sur toutes les interfaces
```

Sur macOS, Podman publie les ports via `gvproxy`, que le pare-feu peut
bloquer (seul `127.0.0.1` répond alors) :

```bash
make firewall        # état
make firewall_allow  # autorise gvproxy (sudo), à refaire après mise à jour de podman
```

## Trunk SIP

Dans `.env`, puis `make reset` :

```bash
TRUNK_HOST=sip.example.net   # domaine SIP de la ligne
TRUNK_USER=0033XXXXXXXXX     # numéro de la ligne, sans @domaine
TRUNK_PASSWORD=__PK_DSNPASS_04e7c50b6e8e__
TRUNK_PROXY=                 # SBC de l'opérateur, s'il n'est pas TRUNK_HOST
INBOUND_EXTEN=100            # poste qui sonne sur appel entrant
```

Si l'opérateur fournit un SBC distinct du domaine SIP, le mettre dans
`TRUNK_PROXY` : tout le trafic du trunk lui est envoyé, en proxy sortant.

Vérifier avec `make registrations`. Les numéros `0XXXXXXXXX`, `00...` et
`+...` composés depuis un poste partent par le trunk, tels quels. Tout appel
entrant fait sonner `INBOUND_EXTEN`.

Le trunk a son propre transport (UDP 5070, non publié), pour ne pas annoncer
`PBX_EXTERNAL_IP` à l'opérateur ; son SDP annonce l'adresse publique, détectée
au démarrage (`TRUNK_EXTERNAL_IP=auto`, ou une adresse, ou vide pour l'adresse
privée). Le PABX étant derrière du NAT, les appels entrants dépendent de la
gestion du NAT par l'opérateur (rport, keep-alive via `qualify`). Si la ligne
est déjà enregistrée ailleurs, l'opérateur peut n'envoyer les appels qu'au
dernier enregistrement.

Si l'opérateur refuse l'enregistrement (403, mauvais mot de passe), Asterisk
espace ses tentatives (10 min), pour ne pas faire bloquer la ligne.

## Musique de prédécroché

Avec `PBX_PREANSWER=yes` dans `.env`, l'appelant entrant entend
`sounds/predecroche.wav` en early media (`183 Session Progress` avec SDP,
appel non décroché), puis la sonnerie du poste, relayée dans le flux audio :
l'early media étant déjà établi, Asterisk génère la sonnerie lui-même
(tonalités françaises, [`indications.conf`](config/indications.conf)) au lieu
d'envoyer un `180 Ringing`.

Par défaut, `PBX_PREANSWER=no` : un simple `180 Ringing` sans SDP est envoyé.
Certains opérateurs ignorent le 183, l'appelant n'entendrait alors rien avant
le décroché.

La musique par défaut est une mélodie de démo, générée par `make init`. Pour
utiliser la sienne (non versionnée), convertie en wav 8 kHz mono :

```bash
make preanswer SRC=~/Music/attente.mp3
make reset
```

Le poste `604` permet de l'écouter.

## Captures

Le conteneur `capture` partage le réseau du PABX et y capture en continu le
SIP et le RTP (`tcpdump`), dans un nouveau fichier toutes les 15 minutes, en
gardant les 48 derniers (`CAPTURE_ROTATE`, `CAPTURE_KEEP` dans `.env`). Elles
sont dans `captures/` et sur la page :

```bash
make captures   # ouvre http://127.0.0.1:8080
```

La page liste les captures du PABX (la plus récente, en cours d'écriture, est
téléchargeable à tout moment) et celles du banc de test, à télécharger une à
une ou en `.zip`. Les ouvrir avec Wireshark : Téléphonie > Appels VoIP, pour
voir le diagramme SIP et écouter l'audio, early media compris.

Les captures contiennent l'audio des appels et les échanges
d'authentification SIP : garder `CAPTURE_BIND=127.0.0.1`.

## Banc de test du 183

`make test` vérifie, sans opérateur ni softphone, ce que le PABX envoie à
l'opérateur avant le décroché. Un second PABX, isolé (aucun port publié, pas
de `.env`, la ligne réelle n'est pas enregistrée), reçoit un appel entrant de
SIPp jouant l'opérateur ; un autre SIPp joue le poste `100`, qui sonne 3 s
puis décroche.

```bash
make test_183   # PBX_PREANSWER=yes : 183 avec SDP, pas de 180, RTP pendant
                # la musique et pendant la sonnerie
make test_180   # PBX_PREANSWER=no : 180 sans SDP, pas de 183, pas de RTP
make test       # les deux
```

Chaque test affiche les réponses reçues par l'opérateur, le nombre de paquets
RTP pendant la musique et la sonnerie, puis `PASSED` ou `FAILED` (code de
sortie non nul) :

```text
Carrier got before answer: 100 183 183 200
RTP to carrier before answer: 315 packets during the music, 150 during the ringing
Music played for 6.3 s, extension rang for 3.0 s
ok   183 Session Progress with SDP
ok   no 180 Ringing
...
PASSED
```

La capture est conservée dans `test/out/preanswer-yes.pcap` /
`preanswer-no.pcap`, aussi sur la page des captures, par exemple pour
l'opérateur. Le journal SIPp des messages inattendus est dans
`test/out/preanswer-*-sipp.log`.

Le banc tourne aussi en intégration continue, voir
[`.github/workflows/test.yml`](.github/workflows/test.yml).

## Commandes

| Commande                     | Rôle                                               |
| ---------------------------- | -------------------------------------------------- |
| `make init`                  | crée `.env`, construit les images, démarre         |
| `make up` / `down` / `reset` | démarre / arrête / recrée les conteneurs           |
| `make build`                 | reconstruit les images                             |
| `make logs`                  | journal d'Asterisk                                 |
| `make cli`                   | console Asterisk                                   |
| `make trace`                 | console avec les messages SIP, quitter par Ctrl-C  |
| `make endpoints` / `contacts` / `registrations` / `channels` | état PJSIP |
| `make history_on`, `make history` | historique des messages SIP                   |
| `make captures`              | page des captures                                  |
| `make accounts`              | identifiants des postes                            |
| `make test`                  | banc de test du 183                                |
| `make clean`                 | arrête tout, supprime les captures                 |

Autre version d'Asterisk : `make build ASTERISK_VERSION=22.x.y`.

## Fichiers

| Fichier                         | Rôle                                              |
| ------------------------------- | ------------------------------------------------- |
| `Dockerfile`                    | compilation d'Asterisk, image du PABX             |
| `docker/entrypoint.sh`          | configuration à partir de `.env`, lance Asterisk  |
| `compose.yml`                   | PABX et conteneur de capture                      |
| `config/pjsip.conf`             | transports et postes                              |
| `config/pjsip_trunk.conf`       | trunk, supprimé si `TRUNK_HOST` est vide          |
| `config/extensions.conf`        | plan de numérotation                              |
| `config/modules.conf`           | modules chargés, uniquement ceux utilisés         |
| `capture/`                      | capture `tcpdump` et page de téléchargement       |
| `test/`                         | banc de test du 183 (`make test`)                 |

# Linux Partition Manager

**Partition Wizard** è uno script Bash con un'interfaccia guidata (wizard) per
**espandere e modificare le partizioni dei dischi** su Linux. Funziona sulle
distribuzioni basate su **Debian** (Debian, Ubuntu, Linux Mint, Pop!_OS, ...) e
su quelle basate su **Fedora** (Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux, ...).

La distribuzione viene riconosciuta automaticamente; puoi anche sceglierla tu
con `--distro debian` oppure `--distro fedora`. Gli strumenti che mancano vengono
installati con il gestore di pacchetti giusto (`apt` oppure `dnf`), solo dopo la
tua conferma.

## Avvio rapido

Esegui lo script direttamente da GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh | sudo bash
```

Sui sistemi senza `curl` (ad esempio Debian minimale) puoi usare `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh | sudo bash
```

Per **provare senza modificare nulla** (modalità simulazione: i comandi vengono
solo mostrati):

```bash
curl -fsSL https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh | sudo bash -s -- --dry-run
```

Puoi anche scaricarlo e poi eseguirlo, oppure installarlo come comando:

```bash
curl -fsSLO https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh
chmod +x partition-wizard.sh
sudo ./partition-wizard.sh

# oppure, per averlo sempre disponibile come "partition-wizard":
sudo curl -fsSL -o /usr/local/bin/partition-wizard https://raw.githubusercontent.com/pilippopilippo/linux-partition-manager/main/partition-wizard.sh
sudo chmod +x /usr/local/bin/partition-wizard
```

## Cosa fa

Il menu principale offre:

| Voce | Descrizione |
|------|-------------|
| **Visualizza dischi, partizioni e spazio libero** | Albero dei dischi, spazio non allocato, gruppi di volumi LVM. |
| **Espandi una partizione** | Ingrandisce la partizione nello spazio libero che la segue e poi ne espande il contenuto: volume cifrato LUKS → volume fisico LVM → file system. Funziona anche sulla partizione di sistema in uso. |
| **Riduci una partizione** | Riduce prima il file system e poi la partizione, liberando spazio non allocato. |
| **Crea una nuova partizione** | Crea la tabella delle partizioni (GPT o MBR) se manca, crea la partizione nello spazio libero, la formatta e, se vuoi, la monta e la aggiunge a `/etc/fstab`. |
| **Elimina una partizione** | Elimina una partizione (con conferma digitandone il nome) e commenta le righe di `/etc/fstab` e `/etc/crypttab` che la citano. |
| **Gestisci LVM** | Espande un volume logico usando lo spazio libero del gruppo, oppure aggiunge una partizione a un gruppo di volumi. |
| **Rileva il nuovo spazio di un disco ingrandito** | Dopo aver ingrandito un disco virtuale: rilegge la dimensione del disco e, se serve, estende la tabella GPT fino alla fine del disco. |
| **Ripristina una tabella delle partizioni da backup** | Ripristina uno dei backup salvati automaticamente prima di ogni modifica. |

### File system supportati

| Contenuto | Espansione | Riduzione | Creazione |
|-----------|------------|-----------|-----------|
| ext2 / ext3 / ext4 | ✅ anche montato | ✅ da smontato | ✅ (ext4) |
| XFS | ✅ anche montato | ❌ XFS non si può ridurre | ✅ |
| Btrfs | ✅ anche montato | ✅ anche montato | ✅ |
| NTFS | ✅ da smontato | ✅ da smontato | ✅ |
| FAT32 | ❌ | ❌ | ✅ |
| swap | ✅ (UUID conservato) | ✅ (UUID conservato) | ✅ |
| LVM (volume fisico) | ✅ `pvresize` + espansione del volume logico | ❌ | ✅ |
| LUKS (volume cifrato aperto) | ✅ `cryptsetup resize` + contenuto | ❌ | ❌ |

Tabelle delle partizioni: **GPT** e **MBR/DOS** (comprese le partizioni logiche
dentro una partizione estesa, che viene ingrandita automaticamente quando serve).

## Esempi di utilizzo

**Ho ingrandito il disco della macchina virtuale e voglio usare il nuovo spazio**
1. *Espandi una partizione* → scegli il disco. Lo script rileva la nuova dimensione
   e propone di estendere la tabella GPT.
2. Scegli la partizione (di solito l'ultima, ad esempio la radice `/`) e premi Invio su `max`.
3. Partizione e file system vengono espansi a caldo, senza riavviare.

**Ubuntu con LVM: il volume logico non usa tutto lo spazio del gruppo**
*Gestisci LVM* → *Espandi un volume logico* → scegli `ubuntu-vg/ubuntu-lv` → `max`.

**Aggiungere un disco dati**
*Crea una nuova partizione* → scegli il disco nuovo → GPT → `max` → ext4 →
etichetta → punto di montaggio (es. `/srv/dati`). La partizione viene montata e
aggiunta a `/etc/fstab` con l'opzione `nofail`.

**Fare spazio per una nuova partizione**
*Riduci una partizione* → indica la nuova dimensione (es. `100G` oppure `-50G`),
poi *Crea una nuova partizione* nello spazio liberato.

Le dimensioni si indicano con le unità `M`, `G`, `T` (multipli di 1024), anche
con decimali: `500M`, `20G`, `1.5T`, `+10G` (aggiungi), `-5G` (togli), `max`
(tutto lo spazio disponibile).

## Sicurezza

Modificare le partizioni è sempre un'operazione delicata: **fai un backup dei
dati importanti prima di iniziare**. Lo script cerca comunque di ridurre i rischi:

- prima di ogni modifica salva la tabella delle partizioni in
  `/var/backups/partition-wizard/`; si ripristina dal menu oppure con
  `sudo sfdisk /dev/sdX < file-di-backup`;
- registra ogni comando eseguito in `/var/log/partition-wizard.log`;
- mostra un riepilogo e chiede conferma prima di ogni operazione; per eliminare
  o sovrascrivere dati occorre digitare il nome del dispositivo;
- durante le operazioni critiche `Ctrl+C` viene ignorato, per non lasciare
  file system o tabelle a metà;
- non elimina né smonta le partizioni di sistema (`/`, `/boot`, `/home`, ...);
- con `--dry-run` puoi vedere esattamente quali comandi verrebbero eseguiti.

### Limiti

- Una partizione può crescere solo nello spazio libero che si trova **subito dopo**
  di essa: lo script non sposta le partizioni (per questo serve ad esempio GParted
  da una live USB).
- Ridurre un file system ext4 o NTFS richiede che sia smontato: per la partizione
  di sistema avvia il computer da una live USB ed esegui lo script da lì.
- XFS non può essere ridotto; la riduzione di volumi LVM e LUKS non è automatica.

## Opzioni

```
Uso: partition-wizard.sh [opzioni]

  -n, --dry-run        simulazione: mostra i comandi senza modificare nulla
  -t, --text           interfaccia testuale semplice (senza whiptail)
  -d, --distro NOME    forza la famiglia di distribuzione: debian | fedora
  -l, --list           mostra dischi, partizioni e spazio libero ed esce
      --install-deps   installa tutti gli strumenti necessari ed esce
  -y, --yes            installa le dipendenze senza chiedere conferma
      --include-loop   mostra anche i dispositivi loop (prove su file immagine)
  -h, --help           mostra questo aiuto
  -V, --version        mostra la versione
```

## Requisiti

- Bash 4.2 o successivo e privilegi di root (lo script si riavvia con `sudo` se
  serve).
- Gli strumenti vengono installati automaticamente quando servono, oppure tutti
  insieme con `sudo ./partition-wizard.sh --install-deps`:

| Funzione | Debian / Ubuntu | Fedora / RHEL |
|----------|-----------------|---------------|
| Tabelle delle partizioni (`sfdisk`, `partx`, `lsblk`, ...) | `fdisk`, `util-linux` | `util-linux` |
| Interfaccia a finestre (`whiptail`) | `whiptail` | `newt` |
| ext2/3/4 | `e2fsprogs` | `e2fsprogs` |
| XFS | `xfsprogs` | `xfsprogs` |
| Btrfs | `btrfs-progs` | `btrfs-progs` |
| LVM | `lvm2` | `lvm2` |
| LUKS | `cryptsetup` | `cryptsetup` |
| FAT32 | `dosfstools` | `dosfstools` |
| NTFS | `ntfs-3g` | `ntfsprogs` |

Se `whiptail` non è disponibile (o con `--text`) il wizard usa una semplice
interfaccia a menu numerati.

## Sviluppo e test

I test creano dischi virtuali (file immagine collegati a dispositivi loop) e
verificano le operazioni reali su ext4, XFS, Btrfs, swap, LVM, GPT, MBR con
partizioni logiche e i percorsi completi del wizard. Non toccano i dischi reali.

```bash
sudo ./partition-wizard.sh --install-deps --yes
sudo tests/run-tests.sh
```

Puoi anche provare il wizard su un disco finto:

```bash
truncate -s 2G /tmp/disco.img
sudo losetup -fP --show /tmp/disco.img     # es. /dev/loop0
sudo ./partition-wizard.sh --include-loop
sudo losetup -d /dev/loop0                 # al termine
```

La CI su GitHub Actions esegue ShellCheck, i test su Ubuntu e l'installazione
delle dipendenze su Debian, Ubuntu, Fedora e Rocky Linux.

## Licenza

[MIT](LICENSE)

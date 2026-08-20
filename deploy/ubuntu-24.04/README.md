# Produksjonsoppsett for Ubuntu 24.04

Dette er en vertsspesifikk driftsleveranse. Den endrer ikke Stirling-kildekoden.
Standardoppsettet kjører ett versjonspinnet `fat`-image, lytter bare på
`127.0.0.1:8080` og publiseres privat med Tailscale Serve.

## Verifiserte forutsetninger

- Første stabile utgave med innebygd MCP er `v2.13.0`. Siste stabile utgave ved
  leveransen er `v2.14.3` (2026-08-06).
- `compose.yml` pinner `2.14.3-fat` til OCI-indeks-digest
  `sha256:444c2a995e5266e585cbc22d9613d5b4c11c8ea6ac486a9a05869b55d1775f6a`.
  Plattformdigesten for `linux/amd64` er
  `sha256:abd6a258b79a092e51d5ea57ba66b80a87630348ef43edf7a43ef1257f0fccb0`.
- MCP kjører på `POST /mcp` som JSON-RPC 2.0 over Streamable HTTP.
- MCP ligger i `app/proprietary`, men har ingen `@PremiumEndpoint`- eller
  `@EnterpriseEndpoint`-sperre i denne checkouten. Free-planen dekker alle
  PDF-operasjoner for opptil fem brukere. Ikke sett en dummy-lisens eller
  `premium.enabled=true`. Server/Enterprise kreves ved høyere brukertall eller
  dersom andre lisensbelagte funksjoner aktiveres.
- MCP krever proprietary-flavouren i standard/fat-imaget. Derfor er
  `DISABLE_ADDITIONAL_FEATURES=false`; dette omgår ingen lisenskontroll.
- OCR er uavhengig av AI-motoren.

Den valgfrie AI-overlayen er av som standard. Dokumentasjonen som følger
`v2.14.3` omtaler `stirling_ai` som en cloud-funksjon som ikke er støttet for
selvhosting. `compose.ai.yml` skal derfor bare aktiveres etter eksplisitt
lisens-/supportavklaring, kompatibilitetstest mot den pinnede Java-versjonen og
verifisering av structured-output-støtte i den lokale modellen.

## Observert VM før implementering

Task-sandkassen hadde Ubuntu 24.04.4, `amd64`, 4 vCPU, 15 GiB RAM, 3 GiB swap og
85 GiB ledig disk. Docker 28.0.4 og Compose 2.38.2 var installert. Tailscale var
ikke installert, UFW var inaktiv og INPUT-policyen var åpen. Dette er bare
preflight-bevis fra sandkassen, ikke en bestått produksjonsaksept. Tailscale-,
nettleser-, MetaMCP- og ekstern nettverkstest må kjøres på mål-VM-en.

Profilen reserverer 8 GiB til Stirling, begrenser Java-heapen til 4 GiB og
begrenser prosesskonkurransen. Det lar OCRmyPDF, Tesseract, LibreOffice,
Ghostscript og verten bruke resten av minnet.

## Filer

| Fil | Mål |
|---|---|
| `compose.yml` | `/opt/stirling-pdf/compose.yml` |
| `.env.example` | `/opt/stirling-pdf/.env` (genereres med modus `0600`) |
| `settings.yml` | `/srv/stirling-pdf/config/settings.yml` |
| `tailscale-policy.hujson` | Mal for tailnet-policy |
| `metamcp-servers.json` | Importmal for MetaMCP |
| `scripts/` | `/opt/stirling-pdf/bin/` |
| `systemd/` | Compose- og backupenheter |

Skriptene oppretter data under `/srv/stirling-pdf`. Skrivbare mapper eies av
containerens UID/GID `10001:10001`. `/opt`, backupmappen, `.env`, Compose og
systemd-filene eies av root.

## 1. Forbered Tailscale og backupnøkkel

Aktiver MagicDNS og HTTPS-sertifikater i Tailscale Admin Console. Tilpass og
valider `tailscale-policy.hujson`, og flett reglene inn i eksisterende policy
i stedet for å overskrive andre nødvendige grants. Sett taggene `tag:stirling-pdf`,
`tag:metamcp` og `tag:agent-vm` på riktige noder. Policyen tillater bare HTTPS
på port 443 og administrativ SSH på port 22; den tillater ikke direkte tilgang
til Docker-port 8080. Behold konsoll/OOB-tilgang mens policyen testes.

Generer age-identiteten på en separat administrasjonsmaskin:

```bash
age-keygen -o stirling-backup-identity.txt
age-keygen -y stirling-backup-identity.txt
```

Lagre privatidentiteten offline. Den offentlige `age1...`-verdien brukes ved
installasjon.

## 2. Installer

Kjør fra denne katalogen på mål-VM-en:

```bash
sudo \
  STIRLING_PUBLIC_URL=https://stirling-pdf.<tailnet>.ts.net \
  BACKUP_AGE_RECIPIENT=age1... \
  ./scripts/install-host.sh
```

Skriptet:

1. kontrollerer OS, arkitektur, CPU, RAM, disk, Tailscale og brannmur;
2. installerer Docker fra Dockers offisielle APT-kilde dersom det mangler;
3. installerer Compose, Tailscale, `age` og `jq`;
4. oppretter mapper og UID/GID;
5. laster ned pinnede `eng`, `nor` og `osd` fra `tessdata_fast` 4.1.0 og
   verifiserer SHA-256;
6. genererer bootstrap-passord og engine-secret;
7. validerer Compose, trekker digest-pinnet image og starter systemd-enheten.

Hvis Tailscale ikke allerede er autentisert, fullfør deretter:

```bash
sudo tailscale up --advertise-tags=tag:stirling-pdf
sudo tailscale serve --yes --bg --https=443 http://127.0.0.1:8080
sudo tailscale serve status
sudo tailscale funnel status
```

`funnel status` skal ikke vise en offentlig publisering. Dokumenter den endelige
URL-en som `https://stirling-pdf.<tailnet>.ts.net`.

Docker publiserer aldri på et eksternt grensesnitt. Aktiver vertens brannmur
etter at administrativ tilgang er bevart. Eksempel dersom SSH også går over
Tailscale:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0 to any port 443 proto tcp
sudo ufw allow in on tailscale0 to any port 22 proto tcp
sudo ufw enable
sudo ss -ltnp
```

Ikke aktiver UFW før SSH-tilgangen er verifisert.

## 3. Første innlogging og MCP-bruker

Les bootstrap-passordet lokalt som root:

```bash
sudo sed -n 's/^SECURITY_INITIALLOGIN_PASSWORD=//p' /opt/stirling-pdf/.env
```

1. Logg inn som `admin` over Tailscale HTTPS.
2. Bytt administratorpassordet.
3. Opprett en aktiv, ikke-administrativ lokal bruker bare for MCP.
4. Logg inn som MCP-brukeren og generer brukerens nøkkel under
   **Account → API Keys**. `2.14.3` har én lokal API-nøkkel per bruker og støtter
   ikke server-side nøkkelnavn; merk secret-en `stirling-mcp` i MetaMCP.
5. Legg nøkkelen direkte i MetaMCP sin secret store. Ikke legg den i denne
   `.env`-filen eller i Claude-konfigurasjoner.
6. Fjern bootstrap-hemmeligheten og gjenskap containeren:

```bash
sudo sed -i '/^SECURITY_INITIALLOGIN_PASSWORD=/d' /opt/stirling-pdf/.env
sudo systemctl restart stirling-pdf
```

MCP starter med en eksplisitt allow-liste for vanlige OCR-, side-,
informasjons- og sanitiseringsoperasjoner. Passord- og rettighetsoperasjoner er ikke
åpnet. Før listen utvides skal `stirling_describe_operation` brukes til å
gjennomgå katalogen, og security-/password-operasjoner skal risikovurderes.

I `2.14.3` vises `stirling_convert`, men katalogen eksponerer ingen operasjoner
med todelte converter-stier. LibreOffice-akseptansetesten bruker derfor det
autentiserte REST-endepunktet `/api/v1/convert/file/pdf`. Dette er en dokumentert
versjonsbegrensning, ikke en lisensomgåelse.

Grensene er 16 MiB for hele MCP-requesten og 4 MiB for inline-respons. Base64
øker størrelsen med omtrent 33 prosent. Bruk `stirling_upload` og `fileId` for
flertrinnsjobber, og REST/pipelines for store dokumenter.

## 4. MetaMCP og Playwright

Tilpass URL-en i `metamcp-servers.json`, og importer filen i MetaMCP. Sett bare
denne hemmeligheten i MetaMCP-miljøet/secret store:

```text
STIRLING_MCP_API_KEY=<redigert>
```

Stirling-serveren skal ha typen `STREAMABLE_HTTP`, URL som slutter på `/mcp`
og header `X-API-KEY`. Ikke bruk `/sse`, stdio eller Bearer-feltet.
MetaMCP støtter `${STIRLING_MCP_API_KEY}` i HTTP-headere; kontroller
interpolasjonen med **Test** før lagring og kontroller at logger redigerer
verdien.

Playwright er en separat MetaMCP-server i importmalen og kjører i et eget,
ephemeralt, digest-pinnet containerimage. Dersom MetaMCP selv er containerisert,
skal Docker-socket ikke monteres inn bare for denne STDIO-konfigurasjonen. Kjør
i stedet Playwright-MCP på en egen VM/containervert med Streamable HTTP, bind
den bare til Tailscale eller localhost, og registrer den URL-en separat i
MetaMCP. Begrens nettverk/origins og bruk `--isolated`.

Fra hver autoriserte agent-VM skal både MetaMCP-endepunktet og verktøykatalogen
testes. Stirling-nøkkelen skal fortsatt bare finnes i MetaMCP.

## 5. OCR, pipelines og Telegram

Kontroller språkene:

```bash
sudo docker exec stirling-pdf tesseract --list-langs
```

Listen skal inneholde `eng`, `nor` og `osd`. Kjør `smoke-test.sh` med en ekte,
skannet norsk/engelsk PDF. Startkonfigurasjonen tillater én OCRmyPDF-jobb, én
Tesseract-jobb og én LibreOffice-jobb samtidig. Øk bare etter måling av RAM,
CPU og midlertidig disk.

Opprett OCR-, sanitization- og eventuell e-postpipeline i UI-et og eksporter
gyldig JSON. Ikke håndskriv ukjent pipelineskjema. Bruk separate mapper:

```text
/srv/stirling-pdf/pipeline/watchedFolders/<pipeline>
/srv/stirling-pdf/pipeline/finishedFolders/<pipeline>
```

File-readiness krever ti sekunders stabil fil før prosessering. Test en langsom
kopi og en restart med fil i innboksen, og kontroller at det ikke oppstår loop.

Telegram er deaktivert. Før aktivering må pipeline og mapper være testet,
`allowUserIDs` settes til reelle private bruker-ID-er og eventuelt
`allowChannelIDs` settes eksplisitt. En tom allow-liste betyr åpen tilgang.
Ikke legg boten i grupper dersom gruppetilgang ikke er ønsket. Bot-token skal
ligge i en root-eid secret, aldri i Git.

## 6. Drift

```bash
sudo systemctl start stirling-pdf
sudo systemctl stop stirling-pdf
sudo systemctl restart stirling-pdf
sudo docker logs --tail 200 -f stirling-pdf
sudo docker stats stirling-pdf
sudo journalctl -u stirling-pdf -u stirling-pdf-backup
df -h /srv/stirling-pdf /var/lib/docker
```

Docker-logger roteres ved 20 MiB × 5. Filsystemlogger roteres daglig i 14 dager.
Overvåk også `/srv/stirling-pdf/config/heap_dumps`, `/tmp` inne i containeren
og Docker-lagringen.

### Backup og gjenoppretting

Backup stopper containerne kontrollert for en konsistent H2/config-snapshot,
krypterer config, customFiles, pipeline, storage, tessdata og engine-data med
age, og starter dem igjen:

```bash
sudo systemctl start stirling-pdf-backup.service
sudo systemctl status stirling-pdf-backup.service
sudo ls -l /srv/stirling-pdf/backups
```

Test alltid restore til en separat katalog:

```bash
sudo AGE_IDENTITY_FILE=/media/offline/stirling-backup-identity.txt \
  /opt/stirling-pdf/bin/restore-backup.sh \
  /srv/stirling-pdf/backups/stirling-pdf-<tid>.tar.gz.age \
  /srv/stirling-pdf-restore-test
```

Skriptet verifiserer SHA-256, dekryptering og obligatoriske mapper, og nekter å
overskrive live-data.

### Oppdatering

1. Les release notes og test ny tag/digest i staging.
2. Kjør og restore-test en backup.
3. Noter eksisterende `STIRLING_IMAGE` som rollback-verdi.
4. Oppdater bare tag og digest i `/opt/stirling-pdf/.env`.
5. Kjør:

```bash
cd /opt/stirling-pdf
sudo docker compose --env-file .env -f compose.yml config --quiet
sudo docker compose --env-file .env -f compose.yml pull
sudo docker compose --env-file .env -f compose.yml up -d
sudo /opt/stirling-pdf/bin/smoke-test.sh --url "$(
  sudo sed -n 's/^STIRLING_PUBLIC_URL=//p' .env
)"
```

Ikke automatiser major-oppgraderinger uten staging.

### Rollback

Sett `STIRLING_IMAGE` tilbake til forrige tag+digest og kjør `pull`/`up -d`.
Hvis datamigrering gjør det nødvendig, stopp tjenesten og gjenopprett den
verifiserte backupen etter at den nåværende datamappen er flyttet til
karantene. Ikke gjenbruk en nyere database med en eldre app uten eksplisitt
kompatibilitetsbekreftelse.

## 7. Valgfri AI-motor

Aktiver ikke overlayen bare for OCR. Før aktivering må lokalmodellen og
embeddingmodellen støtte de nødvendige API-ene, og chatmodellen må bestå
engine-sjekken for native structured output.

Fyll ut AI-feltene i `/opt/stirling-pdf/.env`, bygg fra den oppgitte checkouten
og installer systemd-drop-in:

```bash
sudo install -d -m 0755 /etc/systemd/system/stirling-pdf.service.d
sudo install -m 0644 /opt/stirling-pdf/stirling-pdf-ai.conf \
  /etc/systemd/system/stirling-pdf.service.d/ai.conf
sudo systemctl daemon-reload
sudo systemctl restart stirling-pdf
sudo docker exec stirling-engine curl -fsS http://localhost:5001/health
```

Port 5001 publiseres ikke. Begge containere bruker samme genererte
`STIRLING_ENGINE_SHARED_SECRET`, engine krever auth, analytics er av og SQLite
lagres i `/srv/stirling-pdf/engine-data`. Kontroller etter fem minutter at
MCP-katalogen viser faktiske `stirling_ai`-capabilities. Fjern drop-in og restart
for å deaktivere AI uten å påvirke OCR eller PDF-verktøy. Systemd-enheten bruker
`set-ai-mode.sh` til å holde den høyt prioriterte `settings.yml`-verdien synkron
med valgt base- eller AI-modus.

## 8. Akseptanse og bevis

Kjør:

```bash
sudo MCP_API_KEY='<midlertidig hentet fra MetaMCP secret store>' \
  /opt/stirling-pdf/bin/smoke-test.sh \
  --url https://stirling-pdf.<tailnet>.ts.net \
  --pdf /secure/test.pdf \
  --ocr-pdf /secure/scannet-norsk-engelsk.pdf \
  --office-file /secure/test.docx \
  --public-ip <offentlig-ip> \
  --restart-test
```

Ikke lagre nøkkelen i shell history; den sikreste kjøringen er å utelate
`MCP_API_KEY` og bruke den skjulte prompten.

Skriptet dokumenterer status, HTTPS-UI, 401 uten nøkkel, `initialize`,
`tools/list`, ekte upload/rotate/download med `fileId`, OCR, LibreOffice via REST,
portbinding og restart-persistens. I tillegg må følgende bevis registreres
manuelt:

1. lokal brukerinnlogging og passordbytte;
2. watched-folder-output etter langsom kopi og restart;
3. ekstern test fra en maskin utenfor tailnet mot offentlig IPv4 og IPv6;
4. MetaMCP-test fra hver autoriserte VM;
5. Playwright synlig som en separat MetaMCP-server;
6. vellykket restore til separat katalog.

Ingen av disse seks punktene kan erklæres bestått før de er kjørt i det reelle
tailnettet.

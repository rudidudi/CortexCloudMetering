# Cortex Cloud Metering – script di sizing AWS e Azure

Script per stimare i **workload Cortex Cloud** (Palo Alto Networks) di un ambiente AWS o Azure,
applicando le regole della *Cortex Cloud Metering Guide*.

Nascono come versione corretta degli script ufficiali
[PaloAltoNetworks/cc-workload-sizing](https://github.com/PaloAltoNetworks/cc-workload-sizing),
che contengono diversi errori di conteggio (vedi [Differenze rispetto agli script ufficiali](#differenze-rispetto-agli-script-ufficiali)).

## Regole di conversione

| Tipo di risorsa | Risorse per 1 workload |
|---|---|
| VM (con o senza container, nodi Kubernetes inclusi) | 1 |
| CaaS – container gestiti (Fargate, App Runner, ACI, Container Apps) | 10 |
| Funzioni serverless (Lambda, Azure Functions) | 25 |
| Cloud bucket (S3, Storage account) | 10 |
| Database PaaS (RDS, Aurora, Redshift, Azure SQL, PostgreSQL/MySQL flexible) | 2 |
| DBaaS (DynamoDB) | 1 TB archiviato |
| Immagini nei registry | 10 scansioni oltre la quota gratuita (10 per workload VM/CaaS) |

L'arrotondamento per eccesso viene applicato **sul totale di ogni categoria**, non account per account.

## Requisiti

- **AWS:** AWS CLI v2. Permessi `ReadOnlyAccess` (oppure `SecurityAudit` + `ViewOnlyAccess`) in ogni account;
  in modalità Organization anche `organizations:ListAccounts` e `sts:AssumeRole`.
- **Azure:** Azure CLI. Ruolo `Reader` sulle subscription (o sul Management Group). Per contare le immagini ACR
  serve anche l'accesso al registry (`AcrPull` o `Reader`) e la sua raggiungibilità di rete.
- **Non serve `jq`**: tutti i filtri usano `--query` (JMESPath) integrato nelle CLI.

Il modo più semplice è lanciarli da **AWS CloudShell** o **Azure Cloud Shell**, dove le CLI sono già pronte.

## Utilizzo

### AWS

```bash
chmod +x aws/cc-sizing-aws.sh

./aws/cc-sizing-aws.sh                  # account corrente, tutte le regioni abilitate
./aws/cc-sizing-aws.sh -o               # tutti gli account dell'Organization
./aws/cc-sizing-aws.sh -o -r MioRuolo   # Organization con un ruolo cross-account diverso
./aws/cc-sizing-aws.sh -n eu-west-1     # una sola regione
./aws/cc-sizing-aws.sh -s               # include anche le EC2 stopped
```

| Opzione | Descrizione |
|---|---|
| `-o` | Modalità Organization: scansiona tutti gli account `ACTIVE` (da lanciare dal management account) |
| `-r <ruolo>` | Ruolo da assumere negli account membri (default `OrganizationAccountAccessRole`) |
| `-n <regione>` | Una sola regione |
| `-s` | Include le istanze EC2 `stopped` |
| `-f <file.csv>` | Nome del CSV di dettaglio |

### Azure

```bash
chmod +x azure/cc-sizing-azure.sh

./azure/cc-sizing-azure.sh                  # tutte le subscription abilitate
./azure/cc-sizing-azure.sh -u <sub-id>      # una sola subscription
./azure/cc-sizing-azure.sh -n westeurope    # una sola location
./azure/cc-sizing-azure.sh -s               # include anche le VM deallocate
```

| Opzione | Descrizione |
|---|---|
| `-u <id\|nome>` | Una sola subscription |
| `-n <location>` | Una sola location |
| `-s` | Include le VM deallocate |
| `-f <file.csv>` | Nome del CSV di dettaglio |

## Output

Ogni script stampa una tabella di riepilogo con risorse, rapporto e workload per categoria, e genera:

- un **CSV** con il dettaglio per account/regione (AWS) o per subscription (Azure), da aprire in Excel;
- un file **`-errori.log`** se qualche chiamata non è riuscita (permessi mancanti, ruolo non assumibile,
  registry non raggiungibile…). In quel caso il riepilogo lo segnala: i conteggi interessati valgono 0.

## Cosa viene contato

### AWS

| Categoria | Cosa si conta |
|---|---|
| VM | Istanze EC2 `running` in tutte le regioni (le **istanze**, non le reservation). I nodi EKS/ECS su EC2 sono già inclusi e vengono mostrati a parte solo come informazione |
| CaaS | Container nei task ECS **Fargate** in esecuzione + servizi App Runner |
| Serverless | Funzioni Lambda in tutte le regioni |
| Bucket | Bucket S3 |
| DB PaaS | Tutte le istanze RDS (MySQL, PostgreSQL, MariaDB, Oracle, SQL Server, **Aurora**, DocumentDB, Neptune), cluster Aurora Serverless v1, cluster Redshift |
| DBaaS | Tabelle DynamoDB, convertite in TB archiviati |
| Immagini | Immagini (manifest) nei repository ECR, al netto della quota gratuita |

### Azure

| Categoria | Cosa si conta |
|---|---|
| VM | VM `running` + istanze dei VM Scale Set *Uniform*. I nodi AKS sono istanze VMSS: inclusi una volta sola e mostrati a parte |
| CaaS | Container nei container group ACI + container definiti nelle Container Apps |
| Serverless | Singole funzioni dentro ogni Function App (se l'app non è leggibile conta 1 e lo segnala) |
| Bucket | Storage account |
| DB PaaS | Database Azure SQL (escluso `master`), SQL Managed Instance, PostgreSQL e MySQL flexible server |
| Immagini | Manifest nei repository ACR, al netto della quota gratuita |

## Limiti noti – da completare a mano o da verificare con Palo Alto

- Non calcolati: **utenti SaaS**, **asset Cloud ASM** non gestiti, pod EKS su Fargate e pod su virtual node AKS
  (servono `kubectl`), Amazon Keyspaces, **Cosmos DB** (DBaaS a TB: lo script ne indica il numero di account).
- **Aurora** è contato per istanza (writer + reader): verificare se Palo Alto lo conta per cluster.
- **Azure SQL** è contato per database, non per server logico (il numero di server è comunque riportato).
- Gli **storage account** Azure sono usati come equivalente dei bucket.
- Lo script fotografa il momento in cui viene lanciato: con autoscaling conviene ripeterlo in orari diversi
  o confrontarlo con la media su 30 giorni.

## Differenze rispetto agli script ufficiali

Problemi trovati in `PaloAltoNetworks/cc-workload-sizing` (versione del 13/05/2026) e corretti qui:

**AWS**
- EC2 contava le *reservation* invece delle istanze (sottostima).
- Contava sempre anche le istanze stopped.
- I nodi EKS venivano sommati una seconda volta alle EC2, con una formula cumulativa errata.
- Lambda, ECS, ECR, RDS, DynamoDB, Redshift ed EKS venivano letti solo nella regione di default.
- Fargate sempre a 0 (confronto con `"Fargate"` invece di `"FARGATE"`).
- Immagini container sempre a 0 (variabile inesistente).
- Aurora mai contato (filtro sul solo motore legacy `aurora`).
- DynamoDB contato come PaaS per tabella invece che come DBaaS a TB.
- In modalità Organization il PaaS veniva sommato in modo cumulativo e il contatore Lambda non si azzerava.
- Gli errori delle chiamate venivano ignorati.

**Azure**
- Ogni immagine ACR valeva 1 workload, senza quota gratuita né divisione per 10.
- Una subscription senza VM contava comunque 1 VM.
- Contava sempre anche le VM deallocate; ignorava i VM Scale Set non AKS.
- Contava le Function App invece delle funzioni, e i container group invece dei container.
- Arrotondamento per subscription (sovrastima con molte subscription piccole).
- Usava i comandi dei *Single Server* PostgreSQL/MySQL/MariaDB, ormai dismessi.

## Test

I test eseguono gli script contro CLI simulate (`tests/mock/`) con dati di cui è noto il risultato corretto:

```bash
pip install jmespath
./tests/run-tests.sh
```

## Disclaimer

Strumento non ufficiale, fornito per stime preliminari. Il conteggio di riferimento ai fini del licensing
è quello concordato con Palo Alto Networks.

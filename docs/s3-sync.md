# s3-sync – Fallback Anleitung

## Voraussetzungen

- Gültige AWS Credentials
- Ein vorhandener S3-Bucket
- IAM-Rechte: `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject` (für --delete)

## Manuelle Schritte (ohne Skript)

### Modus 1: Lokal → S3

```bash
LOCAL_ORDNER="/pfad/zum/ordner"
BUCKET="mein-bucket-name"
REGION="us-east-1"

# Alle Dateien synchronisieren (nur neue/geänderte)
aws s3 sync "$LOCAL_ORDNER" s3://$BUCKET/ --region "$REGION"

# Mit --delete: Dateien im Bucket löschen, die lokal nicht mehr existieren
aws s3 sync "$LOCAL_ORDNER" s3://$BUCKET/ --region "$REGION" --delete

# In einen Unterordner im Bucket
aws s3 sync "$LOCAL_ORDNER" s3://$BUCKET/unterordner/ --region "$REGION"

# Bestimmte Dateitypen ausschließen
aws s3 sync "$LOCAL_ORDNER" s3://$BUCKET/ --region "$REGION" \
  --exclude ".DS_Store" --exclude "*.key"
```

### Modus 2: S3 → Lokal

```bash
BUCKET="mein-bucket-name"
LOCAL_ZIEL="/pfad/zum/zielordner"
REGION="us-east-1"

# Zielordner anlegen falls nicht vorhanden
mkdir -p "$LOCAL_ZIEL"

# Gesamten Bucket herunterladen
aws s3 sync s3://$BUCKET/ "$LOCAL_ZIEL" --region "$REGION"

# Einzelne Datei herunterladen (statt sync)
aws s3 cp s3://$BUCKET/datei.txt "$LOCAL_ZIEL/datei.txt"
```

### Modus 3: S3 → S3

```bash
BUCKET_QUELLE="quell-bucket"
BUCKET_ZIEL="ziel-bucket"
REGION="us-east-1"

# Gesamten Bucket kopieren
aws s3 sync s3://$BUCKET_QUELLE/ s3://$BUCKET_ZIEL/ --region "$REGION"

# Einzelne Datei zwischen Buckets kopieren
aws s3 cp s3://$BUCKET_QUELLE/datei.txt s3://$BUCKET_ZIEL/datei.txt
```

## Erwartete Ausgabe

```
upload: ./datei1.txt to s3://mein-bucket/datei1.txt
upload: ./datei2.png to s3://mein-bucket/datei2.png
```

Keine Ausgabe = Keine Änderungen notwendig (alles aktuell).

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `NoSuchBucket` | Bucket existiert nicht | `s3-create-bucket.sh` ausführen |
| `AccessDenied` | Fehlende Rechte | IAM-Rolle prüfen |
| `Path does not exist` | Lokaler Ordner nicht vorhanden | `mkdir -p $LOCAL_ORDNER` |
| Dateien werden nicht synchronisiert | Zeitstempel identisch | `--exact-timestamps` Flag hinzufügen |

## Rollback / Aufräumen

```bash
# Hochgeladene Dateien aus Bucket löschen
aws s3 rm s3://$BUCKET/ --recursive

# Oder nur einen Unterordner löschen
aws s3 rm s3://$BUCKET/unterordner/ --recursive
```

## Abhängigkeiten zu anderen Modulen

- Vorher: `aws-credentials-update.sh`
- Vorher: `s3-create-bucket.sh` – Ziel-Bucket muss existieren
- Kombinierbar mit: `s3-make-public-oeffentlicherzugriff.sh` – um synchronisierte Dateien öffentlich zu machen

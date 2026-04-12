# s3-upload-datei – Fallback Anleitung

## Voraussetzungen

- Gültige AWS Credentials
- Ein vorhandener S3-Bucket
- IAM-Rechte: `s3:PutObject`, `s3:GetObject`

## Manuelle Schritte (ohne Skript)

### Schritt 1: Datei in S3 hochladen

```bash
DATEI="/pfad/zur/datei.txt"
BUCKET="mein-bucket-name"
REGION="us-east-1"

aws s3 cp "$DATEI" s3://$BUCKET/ --region "$REGION"
```

Für einen Unterordner im Bucket:

```bash
aws s3 cp "$DATEI" s3://$BUCKET/unterordner/datei.txt --region "$REGION"
```

### Schritt 2: Pre-Signed URL generieren (7 Tage gültig)

```bash
BUCKET="mein-bucket-name"
DATEI_KEY="datei.txt"   # Name der Datei im Bucket
REGION="us-east-1"

aws s3 presign s3://$BUCKET/$DATEI_KEY \
  --region "$REGION" \
  --expires-in 604800
```

> `604800` Sekunden = 7 Tage. Für kürzere Zeiträume: 3600 = 1 Stunde, 86400 = 1 Tag.

### Schritt 3: Upload bestätigen

```bash
# Datei im Bucket prüfen
aws s3 ls s3://$BUCKET/$DATEI_KEY

# Details abrufen
aws s3api head-object --bucket "$BUCKET" --key "$DATEI_KEY"
```

## Erwartete Ausgabe

Nach dem Upload:
```
upload: ./datei.txt to s3://mein-bucket/datei.txt
```

Pre-Signed URL (sehr lange URL, beginnt mit `https://`):
```
https://mein-bucket.s3.amazonaws.com/datei.txt?X-Amz-Algorithm=...
```

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `NoSuchBucket` | Bucket existiert nicht | `s3-create-bucket.sh` ausführen |
| `AccessDenied` | Fehlende Schreibrechte | IAM-Rolle prüfen |
| `No such file or directory` | Dateipfad falsch | `ls /pfad/zur/datei` prüfen |
| Pre-Signed URL liefert 403 | URL abgelaufen | Neue URL generieren |

## Rollback / Aufräumen

```bash
# Hochgeladene Datei löschen
aws s3 rm s3://$BUCKET/$DATEI_KEY
```

## Abhängigkeiten zu anderen Modulen

- Vorher: `aws-credentials-update.sh`
- Vorher: `s3-create-bucket.sh` – Bucket muss existieren
- Optional vorher: `s3-student-json.sh` – um die zu uploaden JSON-Datei zu erstellen
- Kombinierbar mit: `s3-make-public-oeffentlicherzugriff.sh` – für dauerhaft öffentlichen Zugriff (Pre-Signed URL läuft ab)

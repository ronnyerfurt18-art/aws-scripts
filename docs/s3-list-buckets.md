# s3-list-buckets – Fallback Anleitung

## Voraussetzungen

- Gültige AWS Credentials
- IAM-Rechte: `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, `s3:ListBucket`, `s3:GetPublicAccessBlock`

## Manuelle Schritte (ohne Skript)

### Schritt 1: Alle Buckets auflisten

```bash
aws s3api list-buckets --query 'Buckets[*].{Name:Name,Erstellt:CreationDate}' --output table
```

### Schritt 2: Details zu einem einzelnen Bucket abrufen

```bash
BUCKET="mein-bucket-name"

# Region ermitteln
aws s3api get-bucket-location --bucket "$BUCKET" --query 'LocationConstraint' --output text

# Anzahl Objekte und Gesamtgröße
aws s3 ls s3://$BUCKET --recursive --human-readable --summarize

# Öffentlichen Zugriff prüfen
aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration.BlockPublicPolicy' --output text
```

### Schritt 3: Kompakte Übersicht aller Buckets (Schleife)

```bash
for BUCKET in $(aws s3api list-buckets --query 'Buckets[*].Name' --output text); do
  REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --query 'LocationConstraint' --output text)
  [ "$REGION" == "None" ] && REGION="us-east-1"
  echo "Bucket: $BUCKET | Region: $REGION"
  aws s3 ls s3://$BUCKET --recursive --human-readable --summarize 2>/dev/null | grep -E "Total"
  echo "---"
done
```

## Erwartete Ausgabe

```
Bucket: mein-bucket | Region: us-east-1
Total Objects: 3
Total Size: 1.2 MiB
---
```

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `ExpiredTokenException` | Session abgelaufen | `aws-credentials-update.sh` ausführen |
| `AccessDenied` | Keine Listberechtigung | IAM-Rolle im Learner Lab prüfen |
| Leere Ausgabe | Keine Buckets vorhanden | Zuerst einen Bucket mit `s3-create-bucket.sh` anlegen |

## Rollback / Aufräumen

Dieses Skript führt keine Änderungen durch – kein Rollback notwendig.

## Abhängigkeiten zu anderen Modulen

- Vorher: `aws-credentials-update.sh`
- Nützlich nach: `s3-create-bucket.sh`, `s3-upload-datei.sh` – um Ergebnisse zu überprüfen

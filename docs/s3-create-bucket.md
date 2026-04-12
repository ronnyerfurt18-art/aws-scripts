# s3-create-bucket – Fallback Anleitung

## Voraussetzungen

- Gültige AWS Credentials (`aws sts get-caller-identity` liefert eine Antwort)
- IAM-Rechte: `s3:CreateBucket`, `s3:PutPublicAccessBlock`, `s3:PutBucketPolicy`
- Bucket-Name muss global eindeutig sein (nur Kleinbuchstaben, Zahlen, Bindestriche)

## Manuelle Schritte (ohne Skript)

### Schritt 1: Bucket erstellen

```bash
# Region festlegen (Standard: us-east-1)
REGION="us-east-1"
BUCKET="mein-bucket-name"

# Bucket erstellen (us-east-1 braucht KEINEN LocationConstraint)
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"

# Für alle anderen Regionen:
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
```

### Schritt 2: Block Public Access deaktivieren

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
```

### Schritt 3: Bucket Policy für öffentlichen Lesezugriff setzen

```bash
# Alle Dateien öffentlich lesbar machen
aws s3api put-bucket-policy --bucket "$BUCKET" --policy '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::BUCKET_NAME/*"
  }]
}'
```

> Hinweis: `BUCKET_NAME` im JSON durch den echten Bucket-Namen ersetzen.

### Schritt 4: Bucket-URL ermitteln

```bash
echo "https://$BUCKET.s3.amazonaws.com/"
```

## Erwartete Ausgabe

Nach `create-bucket`:
```json
{
    "Location": "/mein-bucket-name"
}
```

Der Bucket ist danach unter `https://<name>.s3.amazonaws.com/` erreichbar.

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `BucketAlreadyExists` | Name global vergeben | Anderen Namen wählen (z.B. mit Konto-ID: `mein-bucket-123456`) |
| `BucketAlreadyOwnedByYou` | Bucket gehört dir bereits | Weiter zu Schritt 2 |
| `InvalidBucketName` | Ungültige Zeichen im Namen | Nur Kleinbuchstaben, Zahlen und Bindestriche verwenden |
| `AccessDenied` | Fehlende IAM-Rechte | IAM-Rolle im Learner Lab prüfen |

## Rollback / Aufräumen

```bash
# Alle Objekte löschen
aws s3 rm s3://$BUCKET --recursive

# Bucket löschen
aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
```

## Abhängigkeiten zu anderen Modulen

- Vorher: `aws-credentials-update.sh` – Credentials müssen gültig sein
- Nachher: `s3-upload-datei.sh`, `s3-sync.sh`, `s3-student-json.sh` – setzen einen vorhandenen Bucket voraus

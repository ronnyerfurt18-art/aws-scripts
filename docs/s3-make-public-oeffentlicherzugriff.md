# s3-make-public – Fallback Anleitung

## Voraussetzungen

- Gültige AWS Credentials
- Ein vorhandener S3-Bucket
- IAM-Rechte: `s3:PutPublicAccessBlock`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy`

## Manuelle Schritte (ohne Skript)

### Option A: Bucket öffentlich machen

```bash
BUCKET="mein-bucket-name"

# Schritt 1: Block Public Access deaktivieren
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Schritt 2: Bucket Policy für öffentlichen Lesezugriff setzen
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

### Option B: Bucket einschränken (privat)

```bash
BUCKET="mein-bucket-name"

# Schritt 1: Bucket Policy entfernen
aws s3api delete-bucket-policy --bucket "$BUCKET"

# Schritt 2: Block Public Access aktivieren
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### Schritt 3: Zugriff testen

```bash
BUCKET="mein-bucket-name"
DATEI="beispiel.html"

# URL aufrufen (öffentlich: 200, privat: 403)
curl -I "https://$BUCKET.s3.amazonaws.com/$DATEI"
```

## Erwartete Ausgabe

**Öffentlich:** `HTTP/1.1 200 OK`
**Privat:** `HTTP/1.1 403 Forbidden` mit `<Code>AccessDenied</Code>`

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `MalformedPolicy` | JSON-Fehler in der Policy | Policy-Syntax prüfen, besonders `BUCKET_NAME` ersetzen |
| `403` obwohl public | Block Public Access noch aktiv | Schritt 1 erneut ausführen |
| `NoSuchBucketPolicy` beim Löschen | Keine Policy vorhanden | Kein Problem, mit Schritt 2 weitermachen |

## Rollback / Aufräumen

```bash
# Bucket wieder privat machen (siehe Option B oben)
aws s3api delete-bucket-policy --bucket "$BUCKET"
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

## Abhängigkeiten zu anderen Modulen

- Vorher: `s3-create-bucket.sh` – Bucket muss existieren
- Vorher: `s3-upload-datei.sh` – für den curl-Test muss mindestens eine Datei vorhanden sein

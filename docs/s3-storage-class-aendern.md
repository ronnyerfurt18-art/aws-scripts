# s3-storage-class-aendern – Fallback Anleitung

## Voraussetzungen

- Gültige AWS Credentials
- Ein vorhandener S3-Bucket mit mindestens einer Datei
- IAM-Rechte: `s3:GetObject`, `s3:PutObject`, `s3:ListBucket`

## Speicherklassen im Überblick

| Klasse | Einsatz | Abrufzeit |
|--------|---------|-----------|
| `STANDARD` | Häufig genutzte Daten | Sofort |
| `INTELLIGENT_TIERING` | Unbekanntes Zugriffsmuster | Sofort |
| `STANDARD_IA` | Selten genutzte Daten | Sofort |
| `ONEZONE_IA` | Selten, nur 1 AZ | Sofort |
| `GLACIER_IR` | Archiv mit sofortigem Zugriff | Sofort |
| `GLACIER` | Günstiges Archiv | Minuten bis Stunden |
| `DEEP_ARCHIVE` | Langzeitarchiv | 12–48 Stunden |

## Manuelle Schritte (ohne Skript)

### Schritt 1: Aktuelle Speicherklasse einer Datei prüfen

```bash
BUCKET="mein-bucket-name"
DATEI="beispiel.txt"

aws s3api head-object --bucket "$BUCKET" --key "$DATEI" \
  --query 'StorageClass' --output text
```

> Hinweis: Keine Ausgabe bedeutet `STANDARD`.

### Schritt 2: Alle Dateien mit Speicherklasse auflisten

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --query 'Contents[*].{Datei:Key,Klasse:StorageClass}' --output table
```

### Schritt 3: Speicherklasse ändern (Objekt auf sich selbst kopieren)

```bash
BUCKET="mein-bucket-name"
DATEI="beispiel.txt"
NEUE_KLASSE="GLACIER"   # Gewünschte Klasse eintragen
REGION="us-east-1"

aws s3 cp "s3://$BUCKET/$DATEI" "s3://$BUCKET/$DATEI" \
  --storage-class "$NEUE_KLASSE" \
  --region "$REGION" \
  --metadata-directive COPY
```

### Schritt 4: Änderung bestätigen

```bash
aws s3api head-object --bucket "$BUCKET" --key "$DATEI" \
  --query 'StorageClass' --output text
```

## Erwartete Ausgabe

```
copy: s3://mein-bucket/beispiel.txt to s3://mein-bucket/beispiel.txt
```

Anschließend gibt `head-object` die neue Klasse zurück, z.B. `GLACIER`.

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `InvalidStorageClass` | Falsche Klassenbezeichnung | Exakt so schreiben wie in der Tabelle oben |
| `AccessDenied` | Fehlende Schreibrechte | IAM-Rolle prüfen |
| `NoSuchKey` | Dateiname falsch | `aws s3 ls s3://$BUCKET/` ausführen |

## Rollback / Aufräumen

```bash
# Zurück zu STANDARD wechseln
aws s3 cp "s3://$BUCKET/$DATEI" "s3://$BUCKET/$DATEI" \
  --storage-class STANDARD \
  --region "$REGION" \
  --metadata-directive COPY
```

> Hinweis: Für Objekte in GLACIER oder DEEP_ARCHIVE muss zuerst eine Wiederherstellung (`aws s3api restore-object`) durchgeführt werden, bevor die Klasse geändert werden kann.

## Abhängigkeiten zu anderen Modulen

- Vorher: `s3-create-bucket.sh` – Bucket muss existieren
- Vorher: `s3-upload-datei.sh` oder `s3-student-json.sh` – Datei muss im Bucket vorhanden sein

# s3-student-json – Fallback Anleitung

## Voraussetzungen

- Bash oder Terminal mit `echo`/`cat`-Zugriff
- Kein AWS-Zugriff für die Erstellung notwendig (nur für den Upload)

## Manuelle Schritte (ohne Skript)

### Option A: JSON-Datei manuell erstellen (nano/vim)

```bash
nano student.json
```

Inhalt eintragen (Beispiel mit Studentendaten):

```json
{
  "vorname": "Max",
  "nachname": "Mustermann",
  "matrikelnummer": "12345",
  "kurs": "Cloud Computing",
  "semester": "3"
}
```

Speichern: `Ctrl+O`, `Enter`, `Ctrl+X`

### Option B: JSON direkt per Befehl erstellen

```bash
cat > student.json << 'JSONEOF'
{
  "vorname": "Max",
  "nachname": "Mustermann",
  "matrikelnummer": "12345",
  "kurs": "Cloud Computing",
  "semester": "3"
}
JSONEOF
```

### Schritt 2: JSON-Datei prüfen

```bash
cat student.json
```

### Schritt 3 (optional): Datei in S3 hochladen

```bash
BUCKET="mein-bucket-name"
REGION="us-east-1"

aws s3 cp student.json s3://$BUCKET/student.json --region "$REGION"
```

## Erwartete Ausgabe

```json
{
  "vorname": "Max",
  "nachname": "Mustermann",
  "matrikelnummer": "12345",
  "kurs": "Cloud Computing",
  "semester": "3"
}
```

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `SyntaxError` beim Validieren | Komma fehlt oder überschüssig | Letztes Feld darf kein Komma haben |
| Datei nicht gefunden beim Upload | Falscher Pfad | `ls student.json` ausführen |
| JSON validieren | - | `cat student.json \| python3 -m json.tool` |

## Rollback / Aufräumen

```bash
# Lokale Datei löschen
rm student.json

# Datei aus S3 löschen (falls hochgeladen)
aws s3 rm s3://$BUCKET/student.json
```

## Abhängigkeiten zu anderen Modulen

- Nachher: `s3-upload-datei.sh` – um die erstellte JSON-Datei in einen Bucket hochzuladen
- Nachher: `s3-make-public-oeffentlicherzugriff.sh` – um die Datei öffentlich zugänglich zu machen

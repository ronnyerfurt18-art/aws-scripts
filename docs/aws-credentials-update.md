# aws-credentials-update – Fallback Anleitung

## Voraussetzungen

- AWS CLI installiert (`aws --version`)
- Zugang zum AWS Academy Learner Lab (Browser)
- Schreibrechte auf `~/.aws/credentials`

## Manuelle Schritte (ohne Skript)

### Schritt 1: Credentials aus dem Learner Lab kopieren

1. Learner Lab im Browser öffnen
2. Auf **AWS Details** klicken
3. Neben „AWS CLI" auf **Show** klicken
4. Den gesamten Block markieren und kopieren – er sieht so aus:

```
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

### Schritt 2: Credentials-Datei manuell bearbeiten

```bash
# Sicherheitskopie der alten Credentials anlegen
cp ~/.aws/credentials ~/.aws/credentials.bak

# Datei öffnen und Inhalt ersetzen
nano ~/.aws/credentials
```

Den kopierten Block einfügen (alten Inhalt vorher löschen), dann speichern (`Ctrl+O`, `Enter`, `Ctrl+X`).

### Schritt 3: Verbindung testen

```bash
aws sts get-caller-identity
```

**Erwartete Ausgabe:**
```json
{
    "UserId": "AROA...",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/..."
}
```

## Erwartete Ausgabe

Bei Erfolg gibt `aws sts get-caller-identity` eine JSON-Antwort mit `UserId`, `Account` und `Arn` zurück.

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `ExpiredTokenException` | Credentials sind abgelaufen | Neue Credentials aus dem Learner Lab holen |
| `InvalidClientTokenId` | Key ID falsch kopiert | Gesamten Block nochmal aus AWS Details kopieren |
| `Could not connect to the endpoint URL` | Kein Internet | Netzwerkverbindung prüfen |
| Datei nicht vorhanden | `~/.aws/` existiert nicht | `mkdir -p ~/.aws` ausführen |

## Rollback / Aufräumen

```bash
# Alte Credentials wiederherstellen (falls Backup vorhanden)
cp ~/.aws/credentials.bak ~/.aws/credentials
```

## Abhängigkeiten zu anderen Modulen

Dieses Skript muss **immer zuerst** ausgeführt werden. Alle anderen Skripte setzen gültige Credentials voraus. AWS Academy Credentials laufen nach einigen Stunden ab – vor jeder neuen Arbeitssitzung erneut aktualisieren.

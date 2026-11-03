NOX7 Plattform – kostenloser Start (Prototyp mit Supabase Auth + Datenbank)

DATEIEN
- index.html: Website
- config.js: Supabase Projekt-URL und Publishable/anon Key
- supabase_schema.sql: Tabellen, Trigger und Row Level Security
- README.txt: diese Anleitung

SCHRITT 1 – Supabase-Projekt
1. Öffne https://supabase.com/ und registriere dich.
2. Erstelle ein neues Projekt (Free Plan). Projektnamen z. B. nox7.
3. Wähle eine sichere Datenbank-Passphrase und bewahre sie sicher auf.
4. Warte, bis das Projekt bereit ist.

SCHRITT 2 – Datenbank vorbereiten
1. Im Supabase Dashboard links SQL Editor öffnen.
2. supabase_schema.sql vollständig hineinkopieren und "Run" drücken.
3. Es werden Profile, Posts und Kontakt-Nachrichten samt RLS-Regeln eingerichtet.

SCHRITT 3 – Anmeldung konfigurieren
1. Authentication > URL Configuration öffnen.
2. Für lokale Tests Site URL auf http://localhost:8000 setzen.
3. Nach Veröffentlichung die Vercel-Adresse als Site URL eintragen.
4. Unter Redirect URLs zusätzlich http://localhost:8000/** und https://DEIN-PROJEKT.vercel.app/** eintragen.
5. Authentication > Sign In / Providers: Email aktiv lassen. E-Mail-Bestätigung aktiviert lassen.
Hinweis: Der integrierte Supabase-Test-Mailversand hat enge Limits; für einen größeren öffentlichen Start später eigenen SMTP-Anbieter einrichten.

SCHRITT 4 – Website verbinden
1. Supabase Project Settings > API (oder Connect) öffnen.
2. Project URL kopieren.
3. Den öffentlichen Publishable Key (oder legacy anon key) kopieren.
4. In config.js die beiden Platzhalter ersetzen.
5. NIEMALS den secret/service_role Key in config.js, HTML, GitHub oder Vercel Frontend-Variablen eintragen.

SCHRITT 5 – Lokal testen
1. Im Ordner der Website ein Terminal öffnen.
2. Ausführen: python3 -m http.server 8000
3. Im Browser http://localhost:8000 öffnen.
4. Konto mit eigener E-Mail erstellen, E-Mail bestätigen und anmelden.
5. Profil speichern und Kontaktformular testen.
Hinweis: Direktes Öffnen per file:// kann Auth-Redirects stören; lokalen Webserver verwenden.

SCHRITT 6 – Admin sicher einrichten
1. Registriere zuerst dein eigenes Konto und bestätige die E-Mail.
2. Supabase Dashboard > Authentication > Users öffnen und deine User UUID kopieren.
3. SQL Editor öffnen und ausführen (UUID ersetzen):
   update public.profiles set role = 'admin', game_rank = 'R5' where id = 'DEINE-UUID';
4. Abmelden und neu anmelden. Der Adminbereich für News/Events wird sichtbar.
5. Vergib Admin-/R4-Rechte ausschließlich über das Supabase Dashboard/SQL an vertraute Personen.
Alle neuen Registrierungen erhalten automatisch nur die Rolle "member". Nutzer können ihre Rolle nicht selbst ändern.

SCHRITT 7 – Kostenlos veröffentlichen mit Vercel
1. Erstelle ein GitHub-Konto unter https://github.com/ (falls noch keines vorhanden).
2. Lege ein privates Repository z. B. nox7-website an.
3. Lade index.html, config.js und README.txt hoch. Die SQL-Datei kannst du ebenfalls ablegen.
4. Öffne https://vercel.com/ und melde dich mit GitHub an.
5. Add New > Project wählen, das Repository importieren und deployen.
6. Du erhältst eine kostenlose Testadresse wie https://nox7-website.vercel.app (Name kann variieren).
7. Trage diese Adresse in Supabase Authentication > URL Configuration als Site URL und Redirect URL ein.
8. Bei jeder Änderung an GitHub wird Vercel neu deployen.

SICHERHEIT / EINSCHRÄNKUNGEN
- Die Publishable/anon Key ist absichtlich im Frontend sichtbar. Sicherheit kommt von RLS-Policies.
- Niemals service_role/secret keys veröffentlichen.
- Öffentliche Registrierung bedeutet: jeder kann ein Mitgliedskonto anlegen. Adminrechte werden nie automatisch vergeben.
- Die aktuelle Demo zeigt R4/R5 als Profil-Anzeige; echte Berechtigungen liegen separat in role und werden nur von Admins gesetzt.
- Vor breitem Start CAPTCHA/Rate Limits, Spam-Schutz und eigenes SMTP konfigurieren.
- Die Kontaktfunktion speichert Nachrichten in der Datenbank; ein E-Mail-Versand ist noch nicht integriert.
- Mitglieder können nur ihren Anzeigenamen selbst ändern. Allianzrang, Rolle und Spielstärke bleiben Admin-Daten und werden über das Supabase Dashboard/SQL gepflegt.
- Vercel Hobby ist laut Bedingungen für persönliche, nicht kommerzielle Nutzung vorgesehen. Für eine kommerzielle Nutzung ist ein passender Tarif erforderlich.
- Free-Tarife haben Limits und können Bedingungen ändern; keine Verfügbarkeitsgarantie für eine produktive Community.

HILFE
Supabase: https://supabase.com/docs
Vercel: https://vercel.com/docs
GitHub: https://docs.github.com


SCHRITT 8 – Vollständiges Löschen eines Mitgliedskontos
1. Die Funktion liegt unter supabase/functions/delete-nox7-member/index.ts.
2. Supabase CLI installieren und im Projektordner mit dem verknüpften Supabase-Projekt ausführen:
   supabase functions deploy delete-nox7-member
3. JWT-Prüfung NICHT deaktivieren. Die Funktion prüft zusätzlich das angemeldete Konto und dessen R4/R5- oder ADMIN-Rechte serverseitig.
4. In der Admin-Mitgliederverwaltung kann ein berechtigter R4/R5/ADMIN ein Mitglied über „Endgültig löschen“ entfernen. Die Bestätigung verlangt zusätzlich die Eingabe „ENDGÜLTIG LÖSCHEN“.
5. Das eigene Konto, das geschützte ADMIN-Konto sowie R5-Konten sind gegen Löschung geschützt.

WICHTIG: Das Löschen über Supabase Auth entfernt das Auth-Konto und das Profil, sofern die profile.id-Fremdschlüsselbeziehung wie vorgesehen ON DELETE CASCADE verwendet. Weitere Tabellen werden nur automatisch mitgelöscht, wenn deren Fremdschlüssel ebenfalls ON DELETE CASCADE besitzen. Storage-Dateien werden dadurch nicht automatisch entfernt. Vor dem produktiven Einsatz die Fremdschlüssel und vorhandene Storage-Buckets prüfen und ein Datenbank-Backup erstellen.

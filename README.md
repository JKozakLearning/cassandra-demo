# Demo Cassandra 5.0: ONE i QUORUM

Lokalny klaster trzech węzłów w Docker Compose, datacenter `dc1`, keyspace RF=3. Port CQL jest dostępny wyłącznie jako `127.0.0.1:9042`.

## Instalacja WSL2 i Ubuntu (Windows)

Poniższe kroki wykonaj w Windows PowerShell uruchomionym jako administrator. WSL2 wymaga obsługiwanej wersji Windows i włączonej wirtualizacji sprzętowej w BIOS/UEFI.

1. Zainstaluj WSL i Ubuntu:

   ```powershell
   wsl --install -d Ubuntu
   ```

   Jeśli polecenie poprosi o restart, uruchom ponownie komputer. Przy pierwszym uruchomieniu Ubuntu utwórz nazwę użytkownika i hasło dla Linuxa. Sprawdź instalację poleceniem `wsl --list --verbose` — Ubuntu powinno mieć wersję `2`. Jeśli ma wersję `1`, ustaw WSL2:

   ```powershell
   wsl --set-version Ubuntu 2
   ```

2. Otwórz Ubuntu z menu Start i zainstaluj Docker Engine bezpośrednio w Ubuntu, razem z pluginem Compose. Poniższe polecenia dodają oficjalne repozytorium Dockera:

   ```bash
   sudo apt update
   sudo apt install -y ca-certificates curl
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
   sudo chmod a+r /etc/apt/keyrings/docker.asc
   sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
   Types: deb
   URIs: https://download.docker.com/linux/ubuntu
   Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
   Components: stable
   Architectures: $(dpkg --print-architecture)
   Signed-By: /etc/apt/keyrings/docker.asc
   EOF
   sudo apt update
   sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```

   Docker Engine działa jako usługa systemd. Aktualne Ubuntu instalowane przez `wsl --install` zwykle ma systemd włączone. Sprawdź i uruchom usługę:

   ```bash
   sudo systemctl enable --now docker
   sudo docker run hello-world
   ```

   Jeśli `systemctl` zgłasza, że system nie został uruchomiony z systemd, włącz je w `/etc/wsl.conf`:

   ```ini
   [boot]
   systemd=true
   ```

   Zapisz plik, zamknij Ubuntu, a w PowerShell wykonaj `wsl --shutdown`; potem ponownie otwórz Ubuntu i uruchom `sudo systemctl enable --now docker`.

   Aby używać `docker` bez `sudo`, dodaj swojego użytkownika do grupy `docker`, a następnie zamknij i otwórz ponownie Ubuntu:

   ```bash
   sudo usermod -aG docker "$USER"
   ```

   Członkostwo w grupie `docker` daje uprawnienia równoważne rootowi. Możesz pominąć ten krok i dodawać `sudo` przed poleceniami Docker.

3. Projekt najlepiej sklonować do katalogu Linuxa (np. `~/cassandra-quorum-demo`), a nie uruchamiać z `/mnt/c`, co zwykle daje lepszą wydajność plików:

   ```bash
   sudo apt update
   sudo apt install -y git
   git clone <URL_REPOZYTORIUM> ~/cassandra-quorum-demo
   cd ~/cassandra-quorum-demo
   ```

   Zastąp `<URL_REPOZYTORIUM>` adresem repozytorium GitHub. Jeśli projekt masz już na dysku Windows, możesz przejść do niego z Ubuntu przez `/mnt/c/...`, np. `cd /mnt/c/Users/<nazwa>/cassandra-quorum-demo`.

## Start w WSL2

Potrzebujesz działającego Docker Engine i pluginu Compose. WSL musi mieć dość pamięci: każdy kontener ma limit 2 GiB, heap JVM 1 GiB. W Ubuntu, w katalogu projektu, sprawdź Docker i uruchom demo:

```bash
docker version
docker compose version
chmod +x demo.sh restore.sh
./demo.sh start
```

Start może potrwać kilka minut przy pierwszym pobraniu obrazu. Węzły startują sekwencyjnie (`cassandra-1`, potem `cassandra-2`, potem `cassandra-3`), żeby uniknąć kolizji tokenów przy równoległym bootstrapie. Skrypt czeka, aż nodetool zgłosi trzy węzły `UN`, wykonuje `init.cql`, a potem uruchamia czytelny podgląd demo: RF, próg QUORUM/ONE, status każdego węzła i aktualne zdarzenia odczytane z tabeli dla `u-42`. Podgląd dopisuje kolejne odświeżenia bez czyszczenia ekranu, więc wcześniejsze polecenia i wyniki zostają widoczne. `Ctrl+C` kończy podgląd, ale zostawia kontenery uruchomione. Etapy A/B/C opisują w terminalu przykładowy zapis, adresy replik partycji (`nodetool getendpoints`), odczyt oraz rezultat wymaganego poziomu spójności.

## Prezentacja

Menu interaktywne: `./demo.sh`. Możesz też uruchamiać etapy osobno:

```bash
./demo.sh a
./demo.sh b
./demo.sh b2
./demo.sh b3
./demo.sh c
./restore.sh
```

- **A — 3/3:** pokazuje `nodetool status`, zapisuje unikalne zdarzenie z bieżącym czasem UTC i nowym UUID przy QUORUM, a następnie odczytuje je z QUORUM. Oczekiwany wynik: sukces.
- **B — 2/3:** zatrzymuje cassandra-3 i czeka, aż `nodetool status` pokaże go jako `DN`, próbuje `ALL`, a potem wykonuje zapis/odczyt QUORUM. Zdarzenia dostają bieżący czas UTC i nowe UUID.
- **B2 — hinted handoff:** po B, gdy cassandra-3 jest wyłączona, `./demo.sh b2` używa istniejącego zapisu `quorum_2of3`, uruchamia cassandra-3, pokazuje logi HintsService/`HintsDispatcher` i odczytuje ten wiersz bezpośrednio z niej. Nie wykonuje dodatkowego zapisu `ONE`.
- **B3 — bootstrap:** `./demo.sh b3` wyłącza hints na cassandra-1/2, zapisuje nowy event przy QUORUM z cassandra-3 down, archiwizuje jej wolumen, usuwa stary Host ID z ringa i uruchamia ją jako świeży węzeł. Pokazuje logi bootstrap/streamingu i odczytuje event lokalnie. Wolumen cassandra-3 jest zastępowany pustym; kopia starego wolumenu pozostaje w `.cassandra3-backup-*`.
- Po operacjach każdego etapu skrypt wykonuje `nodetool flush` i `nodetool compact` na dostępnych węzłach i pokazuje lokalne pliki SSTable. Wyłączone węzły są pomijane. Flush zapisuje lokalny memtable do SSTable; compaction scala SSTable na tym samym węźle. Żadna z tych komend nie rozsyła replik między węzłami.
- **C — 1/3:** zatrzymuje cassandra-2, czeka na detekcję, pokazuje status, oczekuje jawnego błędu CQL dla QUORUM, po czym zapisuje i odczytuje unikalny wiersz przy ONE. Zdarzenia dostają bieżący czas UTC i nowe UUID.
- **Przywrócenie po C:** `./restore.sh` uruchamia oba zatrzymane węzły, czeka na 3 `UN`, pokazuje status i sprawdza odczyt.

Skrypt etapów zakłada, że stan klastra odpowiada etapowi (A: wszystkie węzły działają, B: cassandra-3 zatrzymany, C: cassandra-2 i cassandra-3 zatrzymane). Po C uruchom `./restore.sh` przed ponownym rozpoczęciem.

## Co oznaczają poziomy

RF=3 oznacza trzy repliki każdego wiersza, po jednej na każdy węzeł w `dc1`. `ONE` wymaga potwierdzenia od jednej repliki. `QUORUM` wymaga większości, czyli `floor(3/2)+1 = 2` replik. Dlatego QUORUM działa przy dwóch dostępnych węzłach, a przy jednym zwraca błąd dostępności/timeout; ONE może przy jednym węźle zadziałać. Wybór koordynatora odbywa się przez węzeł cassandra-1.

`nodetool getendpoints demo events_by_user u-42` pokazuje adresy węzłów, które są replikami partycji `u-42` (tabela ma `user_id` jako klucz partycji). To stałe przypisanie wynikające z tokenu i RF, więc lista może zawierać także węzeł `DN`. Polecenie nie potwierdza, że węzeł jest dostępny ani że potwierdził konkretny zapis. Przy RF=3 QUORUM potrzebuje odpowiedzi dwóch dostępnych replik; ONE jednej.

## Typowe problemy

- **Permission denied do Docker socket:** sprawdź integrację WSL2 w Docker Desktop albo uprawnienia do aktywnego Docker Engine; `docker version` może pokazywać klienta mimo niedostępnego serwera.
- **Węzły nie stają się UN:** sprawdź `docker compose ps`, `docker compose logs cassandra-1 cassandra-2 cassandra-3` i wolną pamięć. Pierwszy start inicjalizuje pliki danych i jest wolniejszy.
- **Port 9042 zajęty:** zatrzymaj lokalny proces Cassandra, który go używa, albo zmień mapowanie w compose i połącz `cqlsh` z nowym portem.
- **QUORUM nadal działa po zatrzymaniu kontenera:** poczekaj na status `DN` przed demonstracją; skrypt daje 35 s. Jeśli failure detector jeszcze nie uznał węzła za niedostępny, odczekaj dłużej.
- **Stare dane po ponownym uruchomieniu:** wolumeny są trwałe; `init.cql` używa `IF NOT EXISTS` i przykładowe klucze są stałe. Nie usuwaj wolumenów, jeśli chcesz zachować dane.

## Bezpieczne zatrzymanie

```bash
docker compose -f docker-compose.yml down
```

To zatrzymuje i usuwa kontenery/sieć projektu, ale pozostawia nazwane wolumeny danych. Nie używaj `down -v`, jeśli chcesz zachować dane.

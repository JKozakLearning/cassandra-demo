#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
compose=(docker compose -f docker-compose.yml)

wait_cluster() {
  local expected="$1" deadline=$((SECONDS+600)) status count
  while (( SECONDS < deadline )); do
    status=$(docker exec cassandra-1 nodetool status 2>/dev/null || true)
    count=$(awk '$1=="UN"{n++} END{print n+0}' <<<"$status")
    if [[ "$count" -ge "$expected" ]]; then return 0; fi
    sleep 5
  done
  echo "Timeout: oczekiwano $expected węzłów UN." >&2
  docker exec cassandra-1 nodetool status || true
  return 1
}

wait_node_down() {
  local target_ip="$1" deadline=$((SECONDS+60)) status
  while (( SECONDS < deadline )); do
    status=$(docker exec cassandra-1 nodetool status 2>/dev/null || true)
    if awk -v ip="$target_ip" '$1=="DN" && $2==ip {found=1} END{exit !found}' <<<"$status"; then
      echo "Cassandra wykryła niedostępny węzeł $target_ip."
      return 0
    fi
    sleep 2
  done
  echo "Timeout: Cassandra nie zgłosiła $target_ip jako DN." >&2
  docker exec cassandra-1 nodetool status || true
  return 1
}

ensure_init() {
  wait_cluster 3
  docker exec -i cassandra-1 cqlsh -e "$(cat init.cql)"
}

live_view() {
  local status count events
  echo 'Podgląd demo. Ctrl+C kończy podgląd; kontenery pozostają uruchomione.'
  while true; do
    status=$(docker exec cassandra-1 nodetool status 2>/dev/null || true)
    count=$(awk '$1=="UN"{n++} END{print n+0}' <<<"$status")
    events=$(docker exec cassandra-1 cqlsh -e "CONSISTENCY ONE; SELECT user_id,occurred_at,event_id,event_type FROM demo.events_by_user WHERE user_id='u-42' LIMIT 10;" 2>/dev/null || true)
    printf '\n=== CASSANDRA QUORUM DEMO | %s ===\n' "$(date '+%H:%M:%S')"
    echo 'Keyspace demo | NetworkTopologyStrategy | dc1 RF=3'
    printf 'Repliki dostępne: %s/3 | QUORUM wymaga 2 | ONE wymaga 1\n\n' "$count"
    echo 'Węzły (UN = działa, DN = niedostępny):'
    if [[ -n "$status" ]]; then
      printf '%s\n' "$status" | awk '/^Datacenter:/{show=1} show && ($1=="Datacenter:" || $1=="Status" || $1=="UN" || $1=="DN"){print}'
    else
      echo 'Brak odpowiedzi nodetool z cassandra-1.'
    fi
    echo
    echo 'Tabela: demo.events_by_user'
    echo 'Klucz partycji: user_id | kolumny: occurred_at, event_id, event_type'
    echo 'Zapis: koordynator cassandra-1 rozsyła mutację do replik wyznaczonych przez token.'
    echo 'Odczyt: koordynator zbiera odpowiedzi wymagane przez poziom spójności.'
    echo
    echo 'Zdarzenia zapisane w tabeli (user_id, occurred_at, event_id, event_type):'
    if [[ -n "$events" ]]; then printf '%s\n' "$events"; else echo 'Odczyt CQL chwilowo niedostępny.'; fi
    echo
    echo 'Etapy demo: ./demo.sh a, ./demo.sh b, ./demo.sh c.'
    sleep 5
  done
}

show_replica_placement() {
  local user_id="$1" endpoint node_ip
  echo 'Rozkład repliki dla partycji (nodetool getendpoints):'
  while IFS= read -r endpoint; do
    [[ -z "$endpoint" ]] && continue
    node_ip='nieznany węzeł'
    for node in cassandra-1 cassandra-2 cassandra-3; do
      if [[ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$node" 2>/dev/null || true)" == "$endpoint" ]]; then
        node_ip="$node"
        break
      fi
    done
    printf '  %-15s -> %s\n' "$endpoint" "$node_ip"
  done < <(docker exec cassandra-1 nodetool getendpoints demo events_by_user "$user_id" 2>/dev/null || true)
  echo "getendpoints pokazuje adresy węzłów będących replikami partycji user_id='$user_id' (klucz partycji tabeli)."
  echo 'Adresy wskazują przypisane repliki, nie ich bieżącą dostępność ani potwierdzenie konkretnego zapisu.'
  echo 'Przy RF=3 są trzy repliki; QUORUM wymaga odpowiedzi 2, a ONE wymaga odpowiedzi 1.'
}

show_hint_logs() {
  local node="$1" limit="${2:-8}"
  docker exec "$node" bash -lc "grep -Ei 'HintsService|HintsDispatcher|hint.{0,40}(dispatch|deliver|creat|writ|flush)|((dispatch|deliver|creat|writ|flush).{0,40}hint)' /opt/cassandra/logs/system.log 2>/dev/null | grep -v 'Config.java' | tail -$limit" || true
}

show_hint_stats() {
  local node="$1" stats
  stats=$(docker exec "$node" nodetool tpstats 2>/dev/null || true)
  echo 'Thread pool: Name | Active | Pending | Completed | Blocked | All time blocked'
  printf '%s\n' "$stats" | awk 'BEGIN{IGNORECASE=1} /HintsDispatcher/{print; found=1} END{if (!found) print "HintsDispatcher: brak danych"}'
  echo 'Messaging: Name | Dropped | 50th | 75th | 95th | 98th | 99th | Max'
  printf '%s\n' "$stats" | awk 'BEGIN{IGNORECASE=1} /HINT_(REQ|RSP)/{print; found=1} END{if (!found) print "HINT_REQ/HINT_RSP: brak danych"}'
}

show_bootstrap_logs() {
  local node="$1" since="$2" logs
  logs=$(docker exec "$node" bash -lc "awk -v since='$since' '/Bootstrap completed|Prepare completed|All sessions completed|Starting streaming to|Beginning stream session/ { if (match(\$0, /20[0-9][0-9]-[0-9-]+T[0-9:,]+/)) { stamp=substr(\$0, RSTART, 19); if (stamp >= since) print } }' /opt/cassandra/logs/system.log 2>/dev/null | tail -12" || true)
  if [[ -n "$logs" ]]; then
    printf '%s\n' "$logs"
  else
    echo 'Brak wpisów bootstrap/streaming w ostatnich liniach logu.'
  fi
}

show_sstables() {
  local node="$1"
  echo "SSTable files on $node (demo.events_by_user):"
  docker exec "$node" bash -lc 'find /var/lib/cassandra/data/demo/events_by_user-* -maxdepth 1 -type f -name "*-Data.db" -printf "%f\\n" 2>/dev/null | sort' || true
}

flush_and_compact() {
  local node
  printf '\n========== FLUSH I COMPACTION ==========\n'
  echo 'Flush zapisuje memtable na dany węzeł do nowych plików SSTable. Compaction scala SSTable lokalnie; nie kopiuje danych na inne węzły.'
  for node in cassandra-1 cassandra-2 cassandra-3; do
    if docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null | grep -qx true; then
      echo "--- $node: flush ---"
      docker exec "$node" nodetool flush demo events_by_user || return 1
      show_sstables "$node"
    else
      echo "--- $node: DOWN, pomijam flush i compaction; brak procesu Cassandra. ---"
    fi
  done
  echo
  echo '--- Compaction na dostępnych węzłach ---'
  for node in cassandra-1 cassandra-2 cassandra-3; do
    if docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null | grep -qx true; then
      echo "$node: nodetool compact demo events_by_user"
      docker exec "$node" nodetool compact demo events_by_user || return 1
      show_sstables "$node"
    fi
  done
  printf '%s\n' '========================================'
}

cql_expect() {
  local consistency="$1" should="$2" event="$3" event_type="$4" timestamp="$5" output rc available
  local cql="CONSISTENCY $consistency; INSERT INTO demo.events_by_user (user_id,occurred_at,event_id,event_type) VALUES ('u-42','$timestamp',$event,'$event_type'); SELECT user_id,occurred_at,event_id,event_type FROM demo.events_by_user WHERE user_id='u-42' AND occurred_at='$timestamp' AND event_id=$event;"
  local red='' reset=''
  if [[ -t 1 ]]; then red=$'\033[31m'; reset=$'\033[0m'; fi
  printf '\n========== CQL %s: %s ==========\n' "$consistency" "$event_type"
  local required=1
  case "$consistency" in ALL) required=3;; QUORUM) required=2;; esac
  available=$(docker exec cassandra-1 nodetool status 2>/dev/null | awk '$1=="UN"{n++} END{print n+0}')
  echo "=== Operacja: $consistency (RF=3; wymagane repliki: $required) ==="
  echo "Zapisujemy event_type='$event_type' dla user_id=u-42, occurred_at=$timestamp."
  echo 'Koordynator: cassandra-1; zapis trafia do replik partycji wyznaczonych przez token.'
  show_replica_placement u-42
  echo 'Odczytujemy ten sam wiersz z poziomem spójności:'
  set +e
  output=$(docker exec -i cassandra-1 cqlsh -e "$cql" 2>&1)
  rc=$?
  set -e
  if [[ "$should" == pass ]]; then
    if (( rc != 0 )) || ! grep -q "$event_type" <<<"$output"; then echo "$output"; echo "FAIL: oczekiwano sukcesu $consistency"; return 1; fi
    echo "$output"
    echo "SUKCES: $consistency zapis i odczyt — odpowiedź uzyskana."
  else
    if grep -Eqi 'Unavailable|ReadTimeout|WriteTimeout|NoHostAvailable|timed out' <<<"$output"; then
      printf '\n%s========== OCZEKIWANY BŁĄD %s ==========\n' "$red" "$consistency"
      printf '%s\n' "$output"
      printf 'Wymagane repliki: %s/3; dostępne w klastrze: %s/3. Ten błąd jest oczekiwany w tym etapie.%s\n' "$required" "$available" "$reset"
      printf '%s\n' '========================================'
      return 0
    fi
    echo "$output"; echo "FAIL: oczekiwano jawnego błędu CQL $consistency (kod klienta $rc)."; return 1
  fi
  printf '%s\n' '----------------------------------------'
}

stage_a() {
  local ts event
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  event=$(cat /proc/sys/kernel/random/uuid)
  printf '\n\n========== ETAP A: 3/3 REPLIK ==========\n'
  ensure_init
  docker exec cassandra-1 nodetool status
  cql_expect QUORUM pass "$event" quorum_3of3 "$ts"
  flush_and_compact
  printf '\n========== KONIEC ETAPU A ==========\n'
}
stage_b() {
  local node_ip ts event_all event_quorum
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  event_all=$(cat /proc/sys/kernel/random/uuid)
  event_quorum=$(cat /proc/sys/kernel/random/uuid)
  printf '%s %s\n' "$ts" "$event_quorum" > .demo-b-event
  printf '\n\n========== ETAP B: AWARIA WĘZŁA 3/3 -> 2/3 ==========\n'
  echo 'Wyłączamy cassandra-3; porównamy ALL i QUORUM.'
  node_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cassandra-3)
  docker stop cassandra-3 >/dev/null
  wait_node_down "$node_ip"
  docker exec cassandra-1 nodetool status
  echo 'Próba ALL (wymaga odpowiedzi wszystkich 3 replik) — oczekiwany błąd przy cassandra-3 down:'
  cql_expect ALL fail "$event_all" all_2of3_should_fail "$ts"
  echo 'Próba QUORUM (wymaga 2 z 3 replik) — oczekiwany sukces przy dwóch działających węzłach:'
  cql_expect QUORUM pass "$event_quorum" quorum_2of3 "$ts"
  flush_and_compact
  printf '\n========== KONIEC ETAPU B ==========\n'
}
stage_c() {
  local node_ip ts event_quorum event_one
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  event_quorum=$(cat /proc/sys/kernel/random/uuid)
  event_one=$(cat /proc/sys/kernel/random/uuid)
  printf '\n\n========== ETAP C: AWARIA WĘZŁA 2/3 -> 1/3 ==========\n'
  echo 'Wyłączamy cassandra-2; sprawdzimy QUORUM i ONE.'
  node_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cassandra-2)
  docker stop cassandra-2 >/dev/null
  wait_node_down "$node_ip"
  docker exec cassandra-1 nodetool status
  cql_expect QUORUM fail "$event_quorum" quorum_1of3_should_fail "$ts"
  cql_expect ONE pass "$event_one" one_1of3 "$ts"
  flush_and_compact
  printf '\n========== KONIEC ETAPU C ==========\n'
}

stage_b2() {
  local ts event
  if [[ ! -f .demo-b-event ]]; then
    echo 'Brak danych eventu B. Uruchom najpierw ./demo.sh b.' >&2
    return 1
  fi
  read -r ts event < .demo-b-event
  echo '=== ETAP B2: hinted handoff po zapisie przy cassandra-3 down ==='
  echo "Używamy zapisu quorum_2of3 z B: event_id=$event, occurred_at=$ts. Dodatkowego zapisu ONE nie wykonujemy."
  echo 'Statystyki hintów przed powrotem cassandra-3:'
  show_hint_stats cassandra-1
  echo 'Ostatnie krótkie logi HintsService na cassandra-1 przed powrotem:'
  show_hint_logs cassandra-1 8
  echo 'Zapis QUORUM z B wykonano, gdy cassandra-3 była niedostępna; koordynator cassandra-1 mógł zachować dla niej hint.'
  echo 'Cassandra-3 jest wyłączona; uruchamiamy ją i czekamy na gotowość CQL.'
  docker compose -f docker-compose.yml start cassandra-3
  wait_cluster 3
  local deadline=$((SECONDS+180)) healthy=false
  while (( SECONDS < deadline )); do
    if docker inspect -f '{{.State.Health.Status}}' cassandra-3 2>/dev/null | grep -qx healthy; then
      healthy=true
      break
    fi
    sleep 3
  done
  if [[ "$healthy" != true ]]; then
    echo 'Timeout: cassandra-3 nie przeszła healthcheck CQL.' >&2
    docker compose -f docker-compose.yml logs --tail=60 cassandra-3 >&2 || true
    return 1
  fi
  docker exec cassandra-1 nodetool status
  echo 'Statystyki hintów po powrocie cassandra-3:'
  show_hint_stats cassandra-1
  echo 'Logi HintsService na cassandra-1 po powrocie:'
  show_hint_logs cassandra-1 8
  echo 'Sprawdzamy dokładny zapis QUORUM z etapu B lokalnie na cassandra-3:'
  docker exec cassandra-3 cqlsh -e "CONSISTENCY LOCAL_ONE; SELECT user_id,occurred_at,event_id,event_type FROM demo.events_by_user WHERE user_id='u-42' AND occurred_at='$ts' AND event_id=$event;"
  echo 'Hints directory na cassandra-1 po wznowieniu węzła (dostarczone hinty mogą już zostać usunięte):'
  docker exec cassandra-1 bash -lc 'find /var/lib/cassandra/hints -type f -printf "%TY-%Tm-%Td %TH:%TM:%TS %s bytes %p\\n" 2>/dev/null | tail -20' || true
  echo 'Log „Finished hinted handoff” potwierdza dostarczenie hintu; „Deleted hint file” oznacza usunięcie go po dostarczeniu.'
}

stage_b3() {
  local node ts event since node_ip old_host_id data_volume status backup_dir deadline healthy=false
  local coordinators=(cassandra-1 cassandra-2)
  event=$(cat /proc/sys/kernel/random/uuid)
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo '=== ETAP B3: nowy event, wymiana cassandra-3 i bootstrap ==='
  wait_cluster 3
  status=$(docker exec cassandra-1 nodetool status)
  node_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cassandra-3)
  old_host_id=$(awk -v ip="$node_ip" '$2==ip {print $7; exit}' <<<"$status")
  data_volume=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/cassandra"}}{{.Name}}{{end}}{{end}}' cassandra-3)
  if [[ -z "$node_ip" || -z "$old_host_id" || -z "$data_volume" ]]; then
    echo 'Nie udało się ustalić IP, Host ID lub wolumenu cassandra-3; przerywam.' >&2
    return 1
  fi
  echo '1) Wyłączamy hinted handoff na cassandra-1/2, by event nie dotarł do węzła przez hint.'
  trap 'for n in cassandra-1 cassandra-2; do docker exec "$n" nodetool enablehandoff >/dev/null 2>&1 || true; done' EXIT
  for node in "${coordinators[@]}"; do docker exec "$node" nodetool disablehandoff; done
  echo '2) Zatrzymujemy cassandra-3.'
  docker stop cassandra-3 >/dev/null
  wait_node_down "$node_ip"
  echo "3) Zapisujemy nowy event repair_missing_replica (event_id=$event, occurred_at=$ts) przy QUORUM."
  docker exec cassandra-1 cqlsh -e "CONSISTENCY QUORUM; INSERT INTO demo.events_by_user (user_id,occurred_at,event_id,event_type) VALUES ('u-42','$ts',$event,'repair_missing_replica');"
  backup_dir=".cassandra3-backup-$(date -u '+%Y%m%dT%H%M%SZ')"
  mkdir -p "$backup_dir"
  backup_dir="$PWD/$backup_dir"
  echo "4) Archiwizujemy stary wolumen cassandra-3 do $backup_dir/cassandra3-volume.tar.gz"
  docker run --rm --user 0:0 --entrypoint bash -v "$data_volume:/from:ro" -v "$backup_dir:/backup" cassandra:5.0 -lc 'tar -czf /backup/cassandra3-volume.tar.gz -C /from .'
  printf '%s\n' "$backup_dir" > .demo-cassandra3-backup-path
  echo "5) Usuwamy stary Host ID $old_host_id z ringa."
  docker exec cassandra-1 nodetool removenode "$old_host_id"
  deadline=$((SECONDS+180))
  while (( SECONDS < deadline )); do
    status=$(docker exec cassandra-1 nodetool status 2>/dev/null || true)
    if ! awk -v ip="$node_ip" '$2==ip {found=1} END{exit !found}' <<<"$status"; then break; fi
    sleep 3
  done
  if awk -v ip="$node_ip" '$2==ip {found=1} END{exit !found}' <<<"$status"; then
    echo 'Timeout: stary węzeł nadal widnieje w ringa.' >&2
    return 1
  fi
  echo '6) Usuwamy stary kontener i wolumen; kopia została zachowana w archiwum.'
  docker compose -f docker-compose.yml rm -sf cassandra-3
  docker volume rm "$data_volume"
  since=$(date -u '+%Y-%m-%dT%H:%M:%S')
  echo '7) Tworzymy cassandra-3 z pustym wolumenem; to uruchamia bootstrap i streaming.'
  docker compose -f docker-compose.yml up -d cassandra-3
  wait_cluster 3
  deadline=$((SECONDS+240))
  while (( SECONDS < deadline )); do
    if docker inspect -f '{{.State.Health.Status}}' cassandra-3 2>/dev/null | grep -qx healthy; then healthy=true; break; fi
    sleep 3
  done
  if [[ "$healthy" != true ]]; then
    echo 'Timeout: nowa cassandra-3 nie przeszła healthcheck CQL.' >&2
    docker compose -f docker-compose.yml logs --tail=80 cassandra-3 >&2 || true
    return 1
  fi
  docker exec cassandra-1 nodetool status
  echo 'Logi bootstrap/streamingu z nowego startu cassandra-3:'
  show_bootstrap_logs cassandra-3 "$since"
  for node in cassandra-1 cassandra-2; do
    echo "--- ślad źródłowy: $node ---"
    show_bootstrap_logs "$node" "$since"
  done
  echo 'Odczyt nowego eventu lokalnie na świeżo dołączonej cassandra-3:'
  docker exec cassandra-3 cqlsh -e "CONSISTENCY LOCAL_ONE; SELECT user_id,occurred_at,event_id,event_type FROM demo.events_by_user WHERE user_id='u-42' AND occurred_at='$ts' AND event_id=$event;"
  echo '8) Przywracamy hinted handoff na cassandra-1/2.'
  for node in "${coordinators[@]}"; do docker exec "$node" nodetool enablehandoff; done
  trap - EXIT
  echo "Stary wolumen zabezpieczono w $backup_dir; nowa cassandra-3 dołączyła przez bootstrap."
}

case "${1:-menu}" in
  start) "${compose[@]}" up -d; wait_cluster 3; ensure_init; docker exec cassandra-1 nodetool status; live_view ;;
  a) stage_a ;;
  b) stage_b ;;
  b2) stage_b2 ;;
  b3) stage_b3 ;;
  c) stage_c ;;
  all) stage_a; stage_b; stage_c ;;
  status) docker exec cassandra-1 nodetool status ;;
  menu)
    while true; do
      echo; echo '1) Uruchom klaster + inicjalizacja'; echo '2) Etap A: 3/3 QUORUM'; echo '3) Etap B: 2/3 QUORUM'; echo '4) Etap C: 1/3 QUORUM/ONE'; echo '5) Status'; echo '6) Przywróć'; echo '7) Etap B2: hinted handoff i powrót cassandra-3'; echo '8) Etap B3: wymiana cassandra-3 i bootstrap (archiwizuje wolumen)'; echo '0) Wyjście'
      read -r -p '> ' choice
      case "$choice" in 1) "$0" start;; 2) "$0" a;; 3) "$0" b;; 4) "$0" c;; 5) "$0" status;; 6) ./restore.sh;; 7) "$0" b2;; 8) "$0" b3;; 0) exit 0;; *) echo 'Nieznana opcja';; esac
    done;;
  *) echo "Użycie: $0 [start|a|b|b2|b3|c|all|status]" >&2; exit 2;;
esac

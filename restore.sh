#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
docker compose -f docker-compose.yml start cassandra-2 cassandra-3
end=$((SECONDS+600))
while (( SECONDS < end )); do
  status=$(docker exec cassandra-1 nodetool status 2>/dev/null || true)
  count=$(awk '$1=="UN"{n++} END{print n+0}' <<<"$status")
  if [[ "$count" -eq 3 ]]; then break; fi
  sleep 5
done
[[ "${count:-0}" -eq 3 ]] || { echo 'Nie osiągnięto 3 węzłów UN' >&2; docker exec cassandra-1 nodetool status; exit 1; }
docker exec cassandra-1 nodetool status
docker exec cassandra-1 cqlsh -e "CONSISTENCY QUORUM; SELECT user_id,occurred_at,event_id,event_type FROM demo.events_by_user WHERE user_id='u-42' LIMIT 10;"
echo 'Odczyt sprawdzony. Po okresie awarii anti-entropy repair (nodetool repair) synchronizuje repliki; hinted handoff dostarcza część zapisów po powrocie. Repair nie został uruchomiony automatycznie.'

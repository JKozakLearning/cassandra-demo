CREATE KEYSPACE IF NOT EXISTS demo WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3};
CREATE TABLE IF NOT EXISTS demo.events_by_user (
  user_id text,
  occurred_at timestamp,
  event_id uuid,
  event_type text,
  PRIMARY KEY ((user_id), occurred_at, event_id)
) WITH CLUSTERING ORDER BY (occurred_at DESC, event_id ASC);
INSERT INTO demo.events_by_user (user_id, occurred_at, event_id, event_type) VALUES ('u-42','2026-11-07T10:00:00Z',11111111-1111-4111-8111-111111111111,'login');
INSERT INTO demo.events_by_user (user_id, occurred_at, event_id, event_type) VALUES ('u-42','2026-11-07T10:05:00Z',22222222-2222-4222-8222-222222222222,'view_item');
INSERT INTO demo.events_by_user (user_id, occurred_at, event_id, event_type) VALUES ('u-42','2026-11-07T10:10:00Z',33333333-3333-4333-8333-333333333333,'purchase');

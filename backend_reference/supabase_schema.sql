create table if not exists public.driving_telemetry_trips (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz,
  ended_at timestamptz,
  status text not null default 'recording',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.driving_telemetry_chunks (
  id uuid primary key default gen_random_uuid(),
  trip_id text not null references public.driving_telemetry_trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  chunk_id text not null,
  chunk_index integer not null,
  chunk_type text not null,
  payload_format text not null,
  schema_version integer not null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  compressed_byte_size integer not null,
  checksum_sha256 text not null,
  storage_path text not null,
  processing_status text not null default 'pending',
  processing_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (trip_id, chunk_id),
  unique (trip_id, chunk_index)
);

create index if not exists driving_telemetry_chunks_processing_idx
  on public.driving_telemetry_chunks (processing_status, created_at);

create index if not exists driving_telemetry_chunks_trip_idx
  on public.driving_telemetry_chunks (trip_id, chunk_index);

alter table public.driving_telemetry_trips enable row level security;
alter table public.driving_telemetry_chunks enable row level security;

create policy "Users read their telemetry trips"
on public.driving_telemetry_trips
for select
using (auth.uid() = user_id);

create policy "Users read their telemetry chunks"
on public.driving_telemetry_chunks
for select
using (auth.uid() = user_id);

insert into storage.buckets (id, name, public)
values ('driving-telemetry', 'driving-telemetry', false)
on conflict (id) do nothing;

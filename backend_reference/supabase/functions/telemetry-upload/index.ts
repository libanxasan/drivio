import { createClient } from 'supabase'

const bucketName = 'driving-telemetry'

function requiredHeader(request: Request, name: string): string {
  const value = request.headers.get(name)
  if (!value) throw new Error(`Missing required header: ${name}`)
  return value
}

function parseInteger(value: string, name: string): number {
  const parsed = Number.parseInt(value, 10)
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`Invalid integer header: ${name}`)
  }
  return parsed
}

function toIso(timestampMillis: number): string {
  return new Date(timestampMillis).toISOString()
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, '0'))
    .join('')
}

async function decodeGzipJson(bytes: Uint8Array): Promise<Record<string, unknown>> {
  const stream = new Blob([bytes])
    .stream()
    .pipeThrough(new DecompressionStream('gzip'))
  const text = await new Response(stream).text()
  const value: unknown = JSON.parse(text)
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Trip manifest payload must be a JSON object')
  }
  return value as Record<string, unknown>
}

async function applyTripManifest(
  admin: ReturnType<typeof createClient>,
  userId: string,
  tripId: string,
  bytes: Uint8Array,
): Promise<void> {
  const manifest = await decodeGzipJson(bytes)
  if (manifest.tripId !== tripId) {
    throw new Error('Trip manifest identifier mismatch')
  }

  const startedAtMillis = Number(manifest.startedAtMillis)
  const endedAtMillis = Number(manifest.endedAtMillis)
  if (!Number.isSafeInteger(startedAtMillis) || !Number.isSafeInteger(endedAtMillis)) {
    throw new Error('Trip manifest timestamps are invalid')
  }

  const telemetry = manifest.telemetry
  const metadata = telemetry && typeof telemetry === 'object' && !Array.isArray(telemetry)
    ? telemetry
    : {}

  const { error } = await admin
    .from('driving_telemetry_trips')
    .update({
      user_id: userId,
      started_at: toIso(startedAtMillis),
      ended_at: toIso(endedAtMillis),
      status: 'closed',
      metadata,
      updated_at: new Date().toISOString(),
    })
    .eq('id', tripId)
    .eq('user_id', userId)

  if (error) throw error
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== 'POST') {
    return Response.json({ message: 'Method not allowed' }, { status: 405 })
  }

  try {
    const authorization = requiredHeader(request, 'authorization')
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const publishableKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    const userClient = createClient(supabaseUrl, publishableKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: userData, error: userError } = await userClient.auth.getUser()
    if (userError || !userData.user) {
      return Response.json({ message: 'Unauthorized' }, { status: 401 })
    }

    const user = userData.user
    const tripId = requiredHeader(request, 'x-trip-id')
    const requestedUserId = requiredHeader(request, 'x-user-id')
    if (requestedUserId !== user.id) {
      return Response.json({ message: 'User identifier mismatch' }, { status: 403 })
    }

    const chunkId = requiredHeader(request, 'x-chunk-id')
    const chunkIndex = parseInteger(
      requiredHeader(request, 'x-chunk-index'),
      'x-chunk-index',
    )
    const chunkType = requiredHeader(request, 'x-chunk-type')
    const payloadFormat = requiredHeader(request, 'x-payload-format')
    const schemaVersion = parseInteger(
      requiredHeader(request, 'x-schema-version'),
      'x-schema-version',
    )
    const expectedChecksum = requiredHeader(request, 'x-checksum-sha256')
    const startedAtMillis = parseInteger(
      requiredHeader(request, 'x-started-at-ms'),
      'x-started-at-ms',
    )
    const endedAtMillis = parseInteger(
      requiredHeader(request, 'x-ended-at-ms'),
      'x-ended-at-ms',
    )

    const bytes = new Uint8Array(await request.arrayBuffer())
    const actualChecksum = await sha256Hex(bytes)
    if (actualChecksum !== expectedChecksum.toLowerCase()) {
      return Response.json({ message: 'Checksum mismatch' }, { status: 422 })
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    const extension = payloadFormat === 'json' ? 'json.gz' : 'dtl.gz'
    const storagePath = `${user.id}/${tripId}/${chunkType}/${chunkIndex}-${chunkId}.${extension}`

    const { error: tripError } = await admin
      .from('driving_telemetry_trips')
      .upsert(
        {
          id: tripId,
          user_id: user.id,
          status: 'recording',
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'id' },
      )
    if (tripError) throw tripError

    const { data: existing } = await admin
      .from('driving_telemetry_chunks')
      .select('id, checksum_sha256')
      .eq('trip_id', tripId)
      .eq('chunk_id', chunkId)
      .maybeSingle()

    if (existing) {
      if (existing.checksum_sha256 !== actualChecksum) {
        return Response.json(
          { message: 'Existing idempotency key has a different checksum' },
          { status: 409 },
        )
      }
      if (chunkType === 'tripManifest' && payloadFormat === 'json') {
        await applyTripManifest(admin, user.id, tripId, bytes)
      }
      return Response.json({
        accepted: true,
        alreadyExisted: true,
        chunkId: existing.id,
      })
    }

    const { error: storageError } = await admin.storage
      .from(bucketName)
      .upload(storagePath, bytes, {
        contentType: 'application/octet-stream',
        upsert: false,
      })
    if (storageError) throw storageError

    const { data: inserted, error: insertError } = await admin
      .from('driving_telemetry_chunks')
      .insert({
        trip_id: tripId,
        user_id: user.id,
        chunk_id: chunkId,
        chunk_index: chunkIndex,
        chunk_type: chunkType,
        payload_format: payloadFormat,
        schema_version: schemaVersion,
        started_at: toIso(startedAtMillis),
        ended_at: toIso(endedAtMillis),
        compressed_byte_size: bytes.byteLength,
        checksum_sha256: actualChecksum,
        storage_path: storagePath,
      })
      .select('id')
      .single()

    if (insertError) {
      await admin.storage.from(bucketName).remove([storagePath])
      throw insertError
    }

    if (chunkType === 'tripManifest' && payloadFormat === 'json') {
      await applyTripManifest(admin, user.id, tripId, bytes)
    }

    return Response.json(
      {
        accepted: true,
        alreadyExisted: false,
        chunkId: inserted.id,
      },
      { status: 201 },
    )
  } catch (error) {
    console.error(error)
    return Response.json(
      { message: error instanceof Error ? error.message : String(error) },
      { status: 400 },
    )
  }
})

#!/usr/bin/env node
/**
 * Firma di DISTRIBUZIONE per TestFlight senza dispositivi registrati (D53).
 *
 * Perché esiste: con la firma automatica di Xcode l'archivio viene firmato con un profilo di SVILUPPO, che richiede
 * almeno un dispositivo registrato nel team («Your team has no devices from which to generate a provisioning profile»).
 * TestFlight però usa un profilo App Store, che NON contiene dispositivi. Qui il certificato di distribuzione e il
 * profilo App Store si creano con la chiave API di App Store Connect (ruolo Admin).
 *
 * IMPORTANTE (27/10/2026, D81): il certificato NON si elimina a fine esecuzione. Apple controlla la firma anche ore dopo
 * l'invio (revisione TestFlight per i gruppi esterni): con il certificato già revocato risponde «ITMS-90035 Invalid
 * Signature» (build 7). Ogni `crea` ritira solo i certificati delle esecuzioni PRECEDENTI, tenendo l'ultima.
 *
 * Comandi (nessun segreto viene stampato; i segreti arrivano da variabili d'ambiente):
 *   crea     --dir <cartella> --bundle <id> [--run <numero>]   ritira i vecchi (tiene l'ultima esecuzione), poi crea certificato + profilo App Store
 *   pulisci  --dir <cartella>                                  elimina SUBITO profilo e certificato creati da «crea» (solo uso manuale: non nel flusso TestFlight)
 *   prossima-build --bundle <id>                            legge tutte le build Apple e restituisce il prossimo numero
 *   attendi  --bundle <id> --build <numero> [--minuti 30]      attende che Apple finisca di elaborare la build e riporta (sola lettura) lo stato per tester interni ed esterni, revisione beta e gruppi
 * Variabili: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contenuto del file .p8) oppure ASC_KEY_PATH (percorso del file).
 */
import { execFileSync } from 'node:child_process'
import { createPrivateKey, sign } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const API = 'https://api.appstoreconnect.apple.com'

const b64url = (buf) => Buffer.from(buf).toString('base64url')

/** Token JWT (ES256) per l'API di App Store Connect: valido pochi minuti, mai salvato. */
export function makeJwt({ keyId, issuerId, privateKeyPem, now = Math.floor(Date.now() / 1000), seconds = 900 }) {
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }))
  const body = b64url(JSON.stringify({ iss: issuerId, iat: now, exp: now + seconds, aud: 'appstoreconnect-v1' }))
  const signature = sign('sha256', Buffer.from(`${head}.${body}`), { key: createPrivateKey(privateKeyPem), dsaEncoding: 'ieee-p1363' })
  return `${head}.${body}.${b64url(signature)}`
}

/** Sintesi leggibile di un errore dell'API (titolo e dettaglio, mai le intestazioni né il token). */
export function describeApiError(status, json) {
  const errs = Array.isArray(json?.errors) ? json.errors : []
  const text = errs.map((e) => [e.code, e.title, e.detail].filter(Boolean).join(' · ')).join(' | ')
  return `HTTP ${status}${text ? `: ${text}` : ''}`
}

export class ApiError extends Error {
  constructor(status, json) {
    super(describeApiError(status, json))
    this.status = status
  }
}

export function credentials(env = process.env) {
  const keyId = env.ASC_KEY_ID
  const issuerId = env.ASC_ISSUER_ID
  const pem = env.ASC_KEY_P8 || (env.ASC_KEY_PATH && existsSync(env.ASC_KEY_PATH) ? readFileSync(env.ASC_KEY_PATH, 'utf8') : '')
  if (!keyId || !issuerId || !pem) throw new Error('Mancano ASC_KEY_ID, ASC_ISSUER_ID o ASC_KEY_P8 (valori non mostrati).')
  return { keyId, issuerId, privateKeyPem: pem }
}

async function api(method, path, body) {
  const token = makeJwt(credentials())
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  let json
  try {
    json = text ? JSON.parse(text) : undefined
  } catch {
    json = undefined
  }
  if (!res.ok) throw new ApiError(res.status, json)
  return json
}

const openssl = () => (existsSync('/usr/bin/openssl') ? '/usr/bin/openssl' : 'openssl')
const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`)
  return i > 0 ? process.argv[i + 1] : fallback
}

/** Estrae un valore stringa dal profilo di provisioning (UUID, Name) con `security cms` (solo macOS). */
export function plistString(xml, key) {
  const m = new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(xml)
  return m?.[1]
}

const CI_PROFILE = /^Biblioteca CI (\d+)-(\d+)$/

/**
 * Profili creati da questa procedura (nome «Biblioteca CI <run>-<tentativo>») da ritirare: tutti tranne gli ultimi
 * `keep` (almeno 1: l'esecuzione più recente resta sempre). Ogni altro profilo non viene toccato.
 */
export function staleCiProfiles(profiles, keep = 1) {
  const tieni = Math.max(1, Math.floor(Number(keep)) || 1)
  const ci = (Array.isArray(profiles) ? profiles : [])
    .map((p) => ({ profile: p, m: CI_PROFILE.exec(p?.attributes?.name ?? '') }))
    .filter((x) => typeof x.profile?.id === 'string' && x.m)
    .map((x) => ({ profile: x.profile, run: BigInt(x.m[1]), attempt: Number(x.m[2]) }))
    .sort((a, b) => (a.run === b.run ? a.attempt - b.attempt : a.run < b.run ? -1 : 1))
  return ci.slice(0, Math.max(0, ci.length - tieni)).map((x) => x.profile)
}

/** Ritira profili e certificati delle esecuzioni precedenti (mai quello dell'ultima). Errori: avviso, non blocco. */
async function ritiraVecchi(keep = 1) {
  const elenco = []
  let next = '/v1/profiles?limit=200&fields[profiles]=name'
  for (let pagina = 0; next && pagina < 5; pagina++) {
    const res = await api('GET', next)
    elenco.push(...(res?.data ?? []))
    const link = res?.links?.next
    next = typeof link === 'string' && link.startsWith(API) ? link.slice(API.length) : undefined
  }
  const vecchi = staleCiProfiles(elenco, keep)
  console.log(`  ok  profili di esecuzioni precedenti: ${elenco.filter((p) => CI_PROFILE.test(p?.attributes?.name ?? '')).length}; da ritirare: ${vecchi.length} (l'ultima esecuzione resta valida)`)
  for (const p of vecchi) {
    const certs = await api('GET', `/v1/profiles/${p.id}/certificates?fields[certificates]=name`).catch(() => undefined)
    for (const [tipo, id, path] of [['profilo', p.id, '/v1/profiles/'], ...(certs?.data ?? []).map((c) => ['certificato', c.id, '/v1/certificates/'])]) {
      try {
        await api('DELETE', `${path}${id}`)
        console.log(`  ok  ${tipo} ${id} di un'esecuzione precedente ritirato`)
      } catch (e) {
        if (e instanceof ApiError && e.status === 404) console.log(`  ${tipo} ${id} già assente`)
        else console.warn(`  ATTENZIONE: ${tipo} ${id} non ritirato (${e.message})`)
      }
    }
  }
}

/** Registra l'identificativo dell'app nel team se manca (Biblioteca: nessuna funzione speciale richiesta). */
export async function registraBundle(bundle, nome = 'Biblioteca Iniziato') {
  const bundles = await api('GET', `/v1/bundleIds?filter[identifier]=${encodeURIComponent(bundle)}&limit=200`)
  const found = bundles.data.find((b) => b.attributes.identifier === bundle)
  if (found) return found
  const nuovo = await api('POST', '/v1/bundleIds', { data: { type: 'bundleIds', attributes: { identifier: bundle, name: nome, platform: 'IOS' } } })
  console.log(`  ok  identificativo ${bundle} registrato nel team (id ${nuovo.data.id})`)
  return nuovo.data
}

async function crea() {
  const dir = arg('dir', 'build/firma')
  const bundle = arg('bundle')
  const run = arg('run', String(Date.now()))
  if (!bundle) throw new Error('Manca --bundle.')
  mkdirSync(dir, { recursive: true })
  const stato = { certificateId: undefined, profileId: undefined }
  const save = () => writeFileSync(join(dir, 'stato.json'), JSON.stringify(stato, null, 2))

  console.log(`== Certificato di distribuzione e profilo App Store per ${bundle} (senza dispositivi)`)
  // prima di crearne uno nuovo (il team ammette pochi certificati di distribuzione) si ritirano quelli vecchi, ma
  // l'ultimo resta: Apple ne ha bisogno valido quando controlla la build alla revisione TestFlight
  await ritiraVecchi(1).catch((e) => console.warn(`  ATTENZIONE: ritiro dei certificati precedenti non riuscito (${e.message}); si prosegue.`))
  execFileSync(openssl(), ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(dir, 'chiave.pem'), '-out', join(dir, 'richiesta.csr'), '-subj', '/CN=Biblioteca CI/O=Biblioteca Iniziato/C=IT'], { stdio: 'ignore' })
  const csr = readFileSync(join(dir, 'richiesta.csr'), 'utf8')

  const cert = await api('POST', '/v1/certificates', { data: { type: 'certificates', attributes: { certificateType: 'DISTRIBUTION', csrContent: csr } } }).catch((e) => {
    if (e instanceof ApiError) {
      console.error(`Creazione del certificato di distribuzione rifiutata da Apple (${e.message}).`)
      if (e.status === 403) console.error('La chiave API non ha il permesso di creare certificati: serve il ruolo Admin (vedi IOS_TESTFLIGHT.md, passo 4).')
      if (e.status === 409) console.error('Il team ha già il numero massimo di certificati di distribuzione: se non servono più, revocarne uno in developer.apple.com → Certificates.')
    }
    throw e
  })
  stato.certificateId = cert.data.id
  save()
  writeFileSync(join(dir, 'certificato.cer'), Buffer.from(cert.data.attributes.certificateContent, 'base64'))
  console.log(`  ok  certificato creato (id ${cert.data.id}, tipo ${cert.data.attributes.certificateType})`)

  const found = await registraBundle(bundle)
  const caps = await api('GET', `/v1/bundleIds/${found.id}/bundleIdCapabilities`)
  const capNames = caps.data.map((c) => c.attributes.capabilityType)
  console.log(`  ok  identificativo registrato (id ${found.id}); funzioni attive: ${capNames.join(', ') || 'nessuna'}`)

  const name = `Biblioteca CI ${run}`
  const profile = await api('POST', '/v1/profiles', {
    data: {
      type: 'profiles',
      attributes: { name, profileType: 'IOS_APP_STORE' },
      relationships: { bundleId: { data: { type: 'bundleIds', id: found.id } }, certificates: { data: [{ type: 'certificates', id: cert.data.id }] } },
    },
  }).catch((e) => {
    if (e instanceof ApiError) console.error(`Creazione del profilo App Store rifiutata da Apple (${e.message}).`)
    throw e
  })
  stato.profileId = profile.data.id
  save()
  const profPath = join(dir, 'profilo.mobileprovision')
  writeFileSync(profPath, Buffer.from(profile.data.attributes.profileContent, 'base64'))
  const xml = execFileSync('security', ['cms', '-D', '-i', profPath], { encoding: 'utf8' })
  stato.profileName = plistString(xml, 'Name') ?? name
  stato.profileUuid = plistString(xml, 'UUID')
  stato.bundleId = bundle
  save()
  console.log(`  ok  profilo App Store creato: «${stato.profileName}» (${stato.profileUuid})`)

  // certificato PEM + archivio .p12 (LibreSSL di sistema: lo legge `security import`; la password non è un segreto, vale solo qui)
  execFileSync(openssl(), ['x509', '-inform', 'der', '-in', join(dir, 'certificato.cer'), '-out', join(dir, 'certificato.pem')])
  execFileSync(openssl(), ['pkcs12', '-export', '-inkey', join(dir, 'chiave.pem'), '-in', join(dir, 'certificato.pem'), '-out', join(dir, 'certificato.p12'), '-passout', 'pass:biblioteca-ci'])
  console.log('  ok  archivio del certificato pronto per il portachiavi temporaneo')
}

async function pulisci() {
  const dir = arg('dir', 'build/firma')
  const file = join(dir, 'stato.json')
  if (!existsSync(file)) return console.log('Niente da eliminare (nessun certificato creato da questa esecuzione).')
  const stato = JSON.parse(readFileSync(file, 'utf8'))
  for (const [tipo, id, path] of [['profilo', stato.profileId, '/v1/profiles/'], ['certificato', stato.certificateId, '/v1/certificates/']]) {
    if (!id) continue
    try {
      await api('DELETE', `${path}${id}`)
      console.log(`  ok  ${tipo} ${id} eliminato da Apple`)
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) console.log(`  ${tipo} ${id} già assente`)
      else console.warn(`  ATTENZIONE: ${tipo} ${id} non eliminato (${e.message}): da togliere a mano in developer.apple.com se resta`)
    }
  }
}

/**
 * Next integer CFBundleVersion, shared by every publishing workflow.
 * All build states count (also PROCESSING/FAILED/expired), across marketing versions.
 * Caller must hold the shared repository workflow concurrency lock until Apple
 * acknowledges the upload. External/manual uploads are not reserved by this read.
 */
export async function nextBuildNumber(bundle, request = api) {
  if (typeof bundle !== 'string' || !/^[A-Za-z0-9.-]+$/.test(bundle)) throw new Error('Identificativo app non valido.')
  const apps = await request('GET', '/v1/apps?filter[bundleId]=' + encodeURIComponent(bundle))
  if (!Array.isArray(apps?.data) || apps.data.length !== 1 || !apps.data[0]?.id || apps.data[0]?.attributes?.bundleId !== bundle)
    throw new Error('App Store Connect non identifica una sola app con il bundle richiesto.')
  const path = '/v1/apps/' + encodeURIComponent(apps.data[0].id) + '/builds'
  let next = path + '?limit=200&fields[builds]=version,processingState'
  let highest = 0
  const seen = new Set()
  const ids = new Set()
  let expectedTotal
  while (next) {
    const url = new URL(next, API)
    if (url.origin !== API || url.pathname !== path || seen.has(url.href) || seen.size >= 1000)
      throw new Error('Paginazione delle build non valida: numero non assegnato.')
    seen.add(url.href)
    const page = await request('GET', url.pathname + url.search)
    if (!Array.isArray(page?.data)) throw new Error('Elenco build non valido: numero non assegnato.')
    if (expectedTotal === undefined) {
      expectedTotal = page.meta?.paging?.total
      if (!Number.isSafeInteger(expectedTotal) || expectedTotal < 0) throw new Error('Conteggio build assente o non valido.')
    } else if (page.meta?.paging?.total !== undefined && page.meta.paging.total !== expectedTotal) {
      throw new Error('Elenco build cambiato durante la lettura: riprovare.')
    }
    for (const build of page.data) {
      if (typeof build?.id !== 'string' || !build.id || ids.has(build.id)) throw new Error('Identità build assente o duplicata.')
      ids.add(build.id)
      const version = build?.attributes?.version
      // This project uses one integer (Apple's first component: at most four digits).
      // A different historical format needs an explicit migration, never parseInt.
      if (build?.type !== 'builds' || typeof version !== 'string' || !/^[1-9][0-9]{0,3}$/.test(version))
        throw new Error('Una build esistente ha un numero non intero o fuori formato: assegnazione interrotta.')
      highest = Math.max(highest, Number(version))
    }
    next = page.links?.next
    if (next != null && typeof next !== 'string') throw new Error('Paginazione delle build non valida.')
  }
  if (ids.size !== expectedTotal) throw new Error('Elenco build incompleto: numero non assegnato.')
  if (highest >= 9999) throw new Error('Numerazione intera esaurita: serve una strategia di versione esplicita.')
  return String(highest + 1)
}

async function prossimaBuild() {
  // Stdout intentionally contains only the validated number for GITHUB_OUTPUT.
  console.log(await nextBuildNumber(arg('bundle')))
}

/**
 * Stato osservato per i TESTER (sola lettura, nessuna modifica ad Apple): stato della build per interni ed esterni, revisione beta, gruppi
 * dell'app e se contengono questa build. Serve a non dichiarare «pronto per gli amici» sul solo caricamento: un gruppo esterno vede la build
 * solo dopo la revisione beta e se la build è stata aggiunta al gruppo. Ogni lettura è indipendente e un errore non ferma nulla.
 * Non legge né stampa indirizzi di posta dei tester.
 */
export async function statoTester(app, build, request = api) {
  const safe = async (path) => {
    try {
      return await request('GET', path)
    } catch {
      return undefined
    }
  }
  const det = await safe(`/v1/buildBetaDetails?filter[build]=${encodeURIComponent(build.id)}`)
  const rev = await safe(`/v1/betaAppReviewSubmissions?filter[build]=${encodeURIComponent(build.id)}`)
  const elenco = await safe(`/v1/apps/${encodeURIComponent(app.id)}/betaGroups?limit=50`)
  const gruppi = []
  for (const g of Array.isArray(elenco?.data) ? elenco.data : []) {
    const dentro = await safe(`/v1/betaGroups/${encodeURIComponent(g.id)}/builds?limit=200&fields[builds]=version`)
    gruppi.push({
      nome: g.attributes?.name,
      interno: Boolean(g.attributes?.isInternalGroup),
      linkPubblico: g.attributes?.publicLinkEnabled ? g.attributes?.publicLink : undefined,
      contieneQuestaBuild: Array.isArray(dentro?.data) ? dentro.data.some((b) => b.id === build.id) : undefined,
    })
  }
  return {
    interno: det?.data?.[0]?.attributes?.internalBuildState,
    esterno: det?.data?.[0]?.attributes?.externalBuildState,
    revisione: rev?.data?.[0]?.attributes?.betaReviewState,
    gruppi,
  }
}

/** Righe leggibili dello stato per i tester. Un dato non letto è «n/d»: mai un'ipotesi. */
export function descriviStatoTester(s) {
  const righe = [`  stato per i tester esterni: ${s.esterno ?? 'n/d'}; revisione beta della build: ${s.revisione ?? 'nessuna richiesta visibile'}`]
  if (!s.gruppi.length) righe.push('  gruppi TestFlight: n/d (nessun gruppo letto)')
  for (const g of s.gruppi) {
    const dentro = g.contieneQuestaBuild === undefined ? 'n/d' : g.contieneQuestaBuild ? 'sì' : 'NO (va aggiunta al gruppo in TestFlight)'
    righe.push(`  gruppo «${g.nome ?? 'senza nome'}» (${g.interno ? 'interno' : 'esterno'}): contiene questa build: ${dentro}${g.linkPubblico ? `; link di installazione: ${g.linkPubblico}` : ''}`)
  }
  return righe
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function attendi() {
  const bundle = arg('bundle')
  const build = arg('build')
  const minuti = Number(arg('minuti', '30'))
  if (!bundle || !build) throw new Error('Servono --bundle e --build.')
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(bundle)}`)
  const app = apps.data[0]
  if (!app) throw new Error(`Nessuna app con identificativo ${bundle} in App Store Connect.`)
  console.log(`App «${app.attributes.name}» (id ${app.id}): attendo l'elaborazione della build ${build} (fino a ${minuti} minuti)`)
  const fine = Date.now() + minuti * 60_000
  let ultimo = ''
  while (Date.now() < fine) {
    const res = await api('GET', `/v1/builds?filter[app]=${app.id}&filter[version]=${encodeURIComponent(build)}&limit=5`)
    const b = res.data[0]
    const stato = b ? b.attributes.processingState : 'NON ANCORA VISIBILE'
    if (stato !== ultimo) {
      console.log(`  ${new Date().toISOString().slice(11, 19)}  stato dell'elaborazione: ${stato}`)
      ultimo = stato
    }
    if (b && stato === 'VALID') {
      const det = await api('GET', `/v1/buildBetaDetails?filter[build]=${b.id}`).catch(() => undefined)
      const interno = det?.data?.[0]?.attributes?.internalBuildState
      console.log(`  ok  elaborazione conclusa; scade il ${b.attributes.expirationDate ?? 'n/d'}; stato per i tester interni: ${interno ?? 'n/d'}`)
      if (interno === 'MISSING_EXPORT_COMPLIANCE') console.log('  Mancano le informazioni sulla crittografia (Export Compliance): rispondere nella scheda della build in TestFlight.')
      // sola lettura: gruppi, revisione beta e stato per gli esterni; un errore qui non cambia l'esito dell'elaborazione
      try {
        for (const riga of descriviStatoTester(await statoTester(app, b))) console.log(riga)
      } catch {
        console.log('  (stato dei tester esterni non leggibile da qui: controllare in App Store Connect → TestFlight)')
      }
      return
    }
    if (b && (stato === 'FAILED' || stato === 'INVALID')) throw new Error(`Apple ha dichiarato la build ${stato}: vedere la mail di App Store Connect e la scheda TestFlight.`)
    await sleep(60_000)
  }
  throw new Error('Tempo scaduto: la build non risulta ancora elaborata. Controllare in App Store Connect → TestFlight.')
}

/** Registra l'identificativo e dice se in App Store Connect esiste già la scheda dell'app (necessaria per TestFlight). */
async function prepara() {
  const bundle = arg('bundle')
  if (!bundle) throw new Error('Manca --bundle.')
  await registraBundle(bundle)
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(bundle)}`)
  if (apps.data?.length) console.log(`  ok  scheda app presente in App Store Connect: «${apps.data[0].attributes.name}» (id ${apps.data[0].id})`)
  else { console.log(`  MANCA la scheda app per ${bundle} in App Store Connect (App → + → Nuova app): va creata dal sito, l'API non lo consente.`); process.exitCode = 3 }
}

/** Gruppo interno «Proprietario» con accesso a tutte le build e, come tester, gli utenti App Store Connect del team. */
async function testerInterno() {
  const bundle = arg('bundle')
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(bundle)}`)
  const app = apps.data?.[0]
  if (!app) throw new Error(`Scheda app per ${bundle} non trovata.`)
  const gruppi = await api('GET', `/v1/apps/${app.id}/betaGroups?limit=50`)
  let gruppo = gruppi.data.find((g) => g.attributes.isInternalGroup)
  if (!gruppo) {
    gruppo = (await api('POST', '/v1/betaGroups', { data: { type: 'betaGroups', attributes: { name: 'Proprietario', isInternalGroup: true, hasAccessToAllBuilds: true },
      relationships: { app: { data: { type: 'apps', id: app.id } } } } })).data
    console.log(`  ok  gruppo interno «${gruppo.attributes.name}» creato (accesso a tutte le build)`)
  } else console.log(`  ok  gruppo interno «${gruppo.attributes.name}» già presente`)
  const utenti = await api('GET', '/v1/users?limit=50')
  for (const u of utenti.data) {
    const { username, firstName, lastName } = u.attributes
    try {
      await api('POST', '/v1/betaTesters', { data: { type: 'betaTesters', attributes: { email: username, firstName, lastName },
        relationships: { betaGroups: { data: [{ type: 'betaGroups', id: gruppo.id }] } } } })
      console.log(`  ok  ${firstName} ${lastName} aggiunto come tester interno`)
    } catch (e) {
      console.log(`  ${firstName} ${lastName}: ${e.message}`)
    }
  }
  const builds = await api('GET', `/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=3`)
  for (const b of builds.data) console.log(`  build ${b.attributes.version}: ${b.attributes.processingState}`)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const cmd = process.argv[2]
  const run = { crea, pulisci, attendi, prepara, 'tester-interno': testerInterno, 'prossima-build': prossimaBuild }[cmd]
  if (!run) {
    console.error('Comando sconosciuto. Usare: crea | pulisci | attendi | prossima-build (vedi il commento in testa al file).')
    process.exit(2)
  }
  run().catch((e) => {
    console.error(`ERRORE (${cmd}): ${e.message}`)
    process.exit(1)
  })
}

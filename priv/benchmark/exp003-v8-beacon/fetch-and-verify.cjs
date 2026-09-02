const crypto = require("node:crypto")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

const EXPECTED_CONTRACT_COMMITMENT = "03b64a144c6de26adea8a9bf0258a6d47537849e6551e665e4302d27971717db"
const EXPECTED_PACKAGE_SHA256 = "9b618b8da542fe6c8336f2652115ebab3bed4bf4047f6471f5364cceeb077bad"
const EXPECTED_LOCK_SHA256 = "0a023b584d59a7b38fe46e7cfc719f2295b7b1cb93a095e428c9d0b14bee2320"
const EXPECTED_RUNTIME_MANIFEST_SHA256 =
  "484bbeb7affaedc301aa59b2715a90d3cea081dddff5e44551fb3bf132ca005a"
const EXPECTED_ROUND = 6430646
const EXPECTED_NOMINAL_UNIX = 1788350400
const EXPECTED_CANONICAL_OUTPUT_ROOT = "test/fixtures/benchmark/exp003-v8-beacon"
const EXPECTED_GLOBAL_CLAIM_PATH = "~/.elara/benchmark/exp003/v8/beacon-fetch.claim.json"
const GLOBAL_CLAIM_ACCOUNT_RELATIVE = ".elara/benchmark/exp003/v8/beacon-fetch.claim.json"
const OUTPUT_FILES = [
  "api.drand.sh.json",
  "drand.cloudflare.com.json",
  "verification.json",
  "verified.json"
]
const CONTRACT_EXCLUDED_FIELDS = [
  "contract_commitment",
  "pre_beacon_qualification",
  "preserved_artifact_sha256",
  "source_identities",
  "beacon.verification_source.sha256",
  "beacon.verification_package.sha256",
  "beacon.verification_package.lock_sha256",
  "beacon.runtime_dependencies.sha256"
]

const sha256 = value => crypto.createHash("sha256").update(value).digest("hex")

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(",")}]`
  }

  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map(key => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`
  }

  return JSON.stringify(value)
}

function semanticProjection(protocol) {
  const projection = structuredClone(protocol)
  delete projection.contract_commitment
  delete projection.pre_beacon_qualification
  delete projection.preserved_artifact_sha256
  delete projection.source_identities

  if (projection.beacon) {
    if (projection.beacon.verification_source) {
      delete projection.beacon.verification_source.sha256
    }

    if (projection.beacon.verification_package) {
      delete projection.beacon.verification_package.sha256
      delete projection.beacon.verification_package.lock_sha256
    }

    if (projection.beacon.runtime_dependencies) {
      delete projection.beacon.runtime_dependencies.sha256
    }
  }

  return projection
}

function contractCommitment(protocol) {
  return sha256(stableStringify(semanticProjection(protocol)))
}

function resolveRepositoryPath(repoRoot, relative, label) {
  if (typeof relative !== "string" || relative === "" || path.isAbsolute(relative)) {
    throw new Error(`${label} is not a repository-relative path`)
  }

  const resolved = path.resolve(repoRoot, relative)

  if (resolved !== repoRoot && !resolved.startsWith(`${repoRoot}${path.sep}`)) {
    throw new Error(`${label} escapes the repository`)
  }

  return resolved
}

function readJson(pathname, label) {
  const bytes = fs.readFileSync(pathname)
  let value

  try {
    value = JSON.parse(bytes)
  } catch (_error) {
    throw new Error(`${label} is not valid JSON`)
  }

  if (!value || Array.isArray(value) || typeof value !== "object") {
    throw new Error(`${label} is not a JSON object`)
  }

  return { bytes, value }
}

function verifyFile(pathname, expectedSha256, label) {
  const bytes = fs.readFileSync(pathname)

  if (sha256(bytes) !== expectedSha256) {
    throw new Error(`${label} digest mismatch`)
  }

  return bytes
}

function verifyIdentity(repoRoot, identity, label) {
  const resolved = resolveRepositoryPath(repoRoot, identity.path, label)
  verifyFile(resolved, identity.sha256, label)
  return resolved
}

function assertCleanNodeEnvironment() {
  if (process.env.NODE_OPTIONS) {
    throw new Error("NODE_OPTIONS must be unset")
  }

  if (process.env.NODE_PATH) {
    throw new Error("NODE_PATH must be unset")
  }

  const major = Number(process.versions.node.split(".")[0])

  if (!Number.isInteger(major) || major < 18 || typeof globalThis.fetch !== "function") {
    throw new Error("the frozen verifier requires an unpreloaded Node.js >=18 runtime with fetch")
  }
}

function verifyRuntimeClosure(runtimeRoot, manifest) {
  if (
    manifest.schema !== "elara.exp003.drand-runtime-closure.v8" ||
    manifest.client !== "drand-client@1.4.2" ||
    manifest.installation !== "npm ci --ignore-scripts" ||
    manifest.loading !== "absolute path only after manifest verification; no node_modules resolution"
  ) {
    throw new Error("unexpected runtime dependency manifest contract")
  }

  if (stableStringify(manifest.allowed_builtin_requires) !== stableStringify(["buffer", "node:crypto"])) {
    throw new Error("unexpected runtime dependency builtin closure")
  }

  if (!Array.isArray(manifest.files) || manifest.files.length !== 2) {
    throw new Error("unexpected runtime dependency file closure")
  }

  const files = new Map()

  for (const identity of manifest.files) {
    const pathname = resolveRepositoryPath(runtimeRoot, identity.path, "runtime dependency")
    const stat = fs.lstatSync(pathname)

    if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== identity.size_bytes) {
      throw new Error(`runtime dependency shape mismatch: ${identity.path}`)
    }

    verifyFile(pathname, identity.sha256, `runtime dependency ${identity.path}`)
    files.set(identity.path, pathname)
  }

  const clientPath = files.get("node_modules/drand-client/build/cjs/index.cjs")
  const packagePath = files.get("node_modules/drand-client/package.json")

  if (!clientPath || !packagePath) {
    throw new Error("runtime dependency closure omits the frozen client")
  }

  const clientSource = fs.readFileSync(clientPath, "utf8")
  const requires = [...clientSource.matchAll(/require\("([^"]+)"\)/g)]
    .map(match => match[1])
    .filter((value, index, values) => values.indexOf(value) === index)
    .sort()

  if (stableStringify(requires) !== stableStringify(manifest.allowed_builtin_requires)) {
    throw new Error("frozen client has an unexpected runtime require closure")
  }

  const installedPackage = JSON.parse(fs.readFileSync(packagePath))

  if (installedPackage.version !== "1.4.2" || installedPackage.main !== "./build/cjs/index.cjs") {
    throw new Error("installed drand-client identity mismatch")
  }

  return clientPath
}

function loadFrozenClient(repoRoot, protocol) {
  assertCleanNodeEnvironment()
  const beacon = protocol.beacon
  const verifierDirectory = path.dirname(__filename)
  const sourcePath = verifyIdentity(repoRoot, beacon.verification_source, "beacon verifier source")

  if (fs.realpathSync(sourcePath) !== fs.realpathSync(__filename)) {
    throw new Error("invoked beacon verifier is not the protocol-pinned source")
  }

  const packagePath = verifyIdentity(repoRoot, beacon.verification_package, "beacon verifier package")

  if (beacon.verification_package.sha256 !== EXPECTED_PACKAGE_SHA256) {
    throw new Error("protocol package identity is not independently anchored")
  }

  const lockPath = resolveRepositoryPath(
    repoRoot,
    beacon.verification_package.lock_path,
    "beacon verifier package lock"
  )
  verifyFile(lockPath, beacon.verification_package.lock_sha256, "beacon verifier package lock")

  if (beacon.verification_package.lock_sha256 !== EXPECTED_LOCK_SHA256) {
    throw new Error("protocol package-lock identity is not independently anchored")
  }

  const packageJson = JSON.parse(fs.readFileSync(packagePath))

  if (
    packageJson.name !== "elara-exp003-v8-drand-verification" ||
    packageJson.dependencies?.["drand-client"] !== "1.4.2"
  ) {
    throw new Error("unexpected verifier package contract")
  }

  const runtimeManifestPath = verifyIdentity(
    repoRoot,
    beacon.runtime_dependencies,
    "runtime dependency manifest"
  )

  if (beacon.runtime_dependencies.sha256 !== EXPECTED_RUNTIME_MANIFEST_SHA256) {
    throw new Error("runtime dependency manifest is not independently anchored")
  }

  const runtimeManifest = JSON.parse(fs.readFileSync(runtimeManifestPath))
  const clientPath = verifyRuntimeClosure(verifierDirectory, runtimeManifest)

  // This is intentionally the first third-party load in the process. The file is
  // addressed absolutely and its complete runtime closure was verified above.
  return require(clientPath)
}

function loadProtocol(protocolPath, expectedProtocolSha256) {
  if (!/^[0-9a-f]{64}$/.test(expectedProtocolSha256 || "")) {
    throw new Error("invalid expected protocol digest")
  }

  const resolvedProtocolPath = path.resolve(protocolPath)
  const { bytes, value: protocol } = readJson(resolvedProtocolPath, "protocol")

  if (sha256(bytes) !== expectedProtocolSha256) {
    throw new Error("protocol digest mismatch")
  }

  const repoRoot = process.cwd()

  if (
    protocol.path !== path.relative(repoRoot, resolvedProtocolPath).split(path.sep).join("/") ||
    resolveRepositoryPath(repoRoot, protocol.path, "protocol path") !== resolvedProtocolPath
  ) {
    throw new Error("protocol path does not identify the invoked protocol")
  }

  if (
    protocol.schema !== "elara.exp003.materialization-protocol.v8" ||
    protocol.preregistration_version !== "ER-3/FND-2-v8" ||
    protocol.mode !== "confirmatory" ||
    protocol.exposure?.future_beacon_committed !== true ||
    protocol.exposure?.held_out_selection_performed !== false
  ) {
    throw new Error("protocol is not the frozen unexposed V8 confirmatory contract")
  }

  const commitment = contractCommitment(protocol)

  if (
    commitment !== EXPECTED_CONTRACT_COMMITMENT ||
    protocol.contract_commitment?.sha256 !== EXPECTED_CONTRACT_COMMITMENT ||
    protocol.contract_commitment?.algorithm !==
      "SHA-256 of canonical protocol after deleting only technical identity/evidence fields listed in excluded_fields" ||
    stableStringify(protocol.contract_commitment?.excluded_fields) !==
      stableStringify(CONTRACT_EXCLUDED_FIELDS)
  ) {
    throw new Error("protocol semantic commitment mismatch")
  }

  return { protocol, protocolBytes: bytes, protocolSha256: expectedProtocolSha256, repoRoot }
}

function expectedChainInfo(beacon) {
  return {
    public_key: beacon.public_key,
    period: beacon.period_seconds,
    genesis_time: beacon.genesis_unix,
    hash: beacon.chain_hash,
    groupHash: beacon.group_hash,
    schemeID: beacon.scheme,
    metadata: { beaconID: beacon.beacon_id }
  }
}

function validateProtocolBeacon(beacon) {
  const expectedRound =
    Math.floor((beacon.nominal_unix - beacon.genesis_unix) / beacon.period_seconds) + 1

  if (
    beacon.round !== expectedRound ||
    beacon.genesis_unix + (beacon.round - 1) * beacon.period_seconds !== beacon.nominal_unix ||
    beacon.round !== EXPECTED_ROUND ||
    beacon.nominal_unix !== EXPECTED_NOMINAL_UNIX ||
    beacon.canonical_output_root !== EXPECTED_CANONICAL_OUTPUT_ROOT ||
    beacon.global_claim_path !== EXPECTED_GLOBAL_CLAIM_PATH
  ) {
    throw new Error("invalid committed round arithmetic")
  }

  if (
    beacon.client !== "drand-client@1.4.2" ||
    stableStringify(beacon.relays) !==
      stableStringify(["https://api.drand.sh", "https://drand.cloudflare.com"]) ||
    beacon.scheme !== "pedersen-bls-chained" ||
    beacon.beacon_id !== "default"
  ) {
    throw new Error("unexpected frozen drand client, relay, or chain frame")
  }

  const expectedPath = `/${beacon.chain_hash}/public/${beacon.round}`

  if (beacon.path !== expectedPath) {
    throw new Error("unexpected chain-qualified beacon path")
  }

  return expectedRound
}

function exactChainInfo(actual, expected) {
  const selected = {
    public_key: actual.public_key,
    period: actual.period,
    genesis_time: actual.genesis_time,
    hash: actual.hash,
    groupHash: actual.groupHash,
    schemeID: actual.schemeID,
    metadata: { beaconID: actual.metadata?.beaconID }
  }

  if (stableStringify(selected) !== stableStringify(expected)) {
    throw new Error("relay chain info does not match the frozen chain contract")
  }

  return selected
}

function selectedBeaconFields(result) {
  const selected = {
    round: result.round,
    randomness: result.randomness,
    signature: result.signature,
    previous_signature: result.previous_signature
  }

  if (
    !Number.isSafeInteger(selected.round) ||
    !/^[0-9a-f]{64}$/.test(selected.randomness || "") ||
    !/^[0-9a-f]{192}$/.test(selected.signature || "") ||
    !/^[0-9a-f]{192}$/.test(selected.previous_signature || "")
  ) {
    throw new Error("beacon fields have an invalid chained-default-mainnet shape")
  }

  return selected
}

async function verifyBeaconOffline(clientLibrary, chainInfo, fields, expectedRound) {
  const chain = { info: async () => chainInfo }
  const client = {
    options: { disableBeaconVerification: false },
    get: async round => {
      if (round !== expectedRound) throw new Error("offline verifier round mismatch")
      return fields
    },
    chain: () => chain
  }

  try {
    return selectedBeaconFields(await clientLibrary.fetchBeacon(client, expectedRound))
  } catch (error) {
    throw new Error(`offline drand BLS verification failed: ${error.message}`)
  }
}

function canonicalJsonBytes(value) {
  return Buffer.from(`${stableStringify(value)}\n`)
}

function readCanonicalBundleJson(bundleRoot, relative) {
  const pathname = path.join(bundleRoot, relative)
  const stat = fs.lstatSync(pathname)

  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`beacon bundle path is not a regular file: ${relative}`)
  }

  const { bytes, value } = readJson(pathname, `beacon bundle ${relative}`)

  if (!bytes.equals(canonicalJsonBytes(value))) {
    throw new Error(`beacon bundle JSON is not canonical: ${relative}`)
  }

  return { bytes, value }
}

function assertExactBundleFrame(bundleRoot) {
  const stat = fs.lstatSync(bundleRoot)

  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error("beacon bundle root is not a regular directory")
  }

  const entries = fs.readdirSync(bundleRoot, { withFileTypes: true })

  if (
    entries.some(entry => !entry.isFile()) ||
    stableStringify(entries.map(entry => entry.name).sort()) !== stableStringify([...OUTPUT_FILES].sort())
  ) {
    throw new Error("beacon bundle does not have the exact frozen four-file frame")
  }
}

function verifyPermanentClaim(claimPath, verification, expected) {
  const stat = fs.lstatSync(claimPath)

  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error("permanent beacon claim is not a regular file")
  }

  const { bytes: claimBytes, value: claim } = readJson(claimPath, "permanent beacon claim")

  if (!claimBytes.equals(canonicalJsonBytes(claim))) {
    throw new Error("permanent beacon claim is not canonical")
  }

  if (sha256(claimBytes) !== verification.claim_sha256) {
    throw new Error("permanent beacon claim digest mismatch")
  }

  if (
    claim.schema !== "elara.exp003.beacon-fetch-claim.v8" ||
    claim.protocol_sha256 !== expected.protocolSha256 ||
    claim.contract_commitment !== EXPECTED_CONTRACT_COMMITMENT ||
    claim.round !== EXPECTED_ROUND ||
    claim.canonical_output_root !== EXPECTED_CANONICAL_OUTPUT_ROOT ||
    typeof claim.claimed_at !== "string" ||
    Number.isNaN(Date.parse(claim.claimed_at))
  ) {
    throw new Error("permanent beacon claim is not bound to the frozen attempt")
  }

  return claim
}

function verifyInitialAuthority(loaded, bundleRoot, verification) {
  const { protocol, protocolSha256, repoRoot } = loaded
  const beacon = protocol.beacon
  const expectedBundleRoot = resolveRepositoryPath(
    repoRoot,
    EXPECTED_CANONICAL_OUTPUT_ROOT,
    "canonical beacon output root"
  )

  if (path.resolve(bundleRoot) !== expectedBundleRoot) {
    throw new Error("initial beacon verification requires the canonical output root")
  }

  if (beacon.global_claim_path !== EXPECTED_GLOBAL_CLAIM_PATH) {
    throw new Error("protocol global claim declaration mismatch")
  }

  verifyPermanentClaim(fixedClaimPath(), verification, { protocolSha256 })
}

async function verifyBundle(loaded, bundleRoot, expectedVerificationSha256, authority) {
  const { protocol, protocolSha256, repoRoot } = loaded
  const beacon = protocol.beacon
  validateProtocolBeacon(beacon)
  const clientLibrary = loadFrozenClient(repoRoot, protocol)
  const resolvedBundleRoot = path.resolve(bundleRoot)

  if (authority === "initial") {
    const expected = resolveRepositoryPath(
      repoRoot,
      EXPECTED_CANONICAL_OUTPUT_ROOT,
      "canonical beacon output root"
    )

    if (resolvedBundleRoot !== expected) {
      throw new Error("initial beacon verification requires the canonical output root")
    }
  } else if (authority !== "copy") {
    throw new Error("unknown beacon bundle authority mode")
  }

  assertExactBundleFrame(resolvedBundleRoot)

  const relayA = readCanonicalBundleJson(resolvedBundleRoot, "api.drand.sh.json")
  const relayB = readCanonicalBundleJson(resolvedBundleRoot, "drand.cloudflare.com.json")
  const verification = readCanonicalBundleJson(resolvedBundleRoot, "verification.json")
  const verified = readCanonicalBundleJson(resolvedBundleRoot, "verified.json")

  if (sha256(verification.bytes) !== expectedVerificationSha256) {
    throw new Error("beacon verification receipt digest mismatch")
  }

  if (
    verification.value.schema !== "elara.exp003.beacon-verification.v8" ||
    verification.value.protocol_sha256 !== protocolSha256 ||
    verification.value.contract_commitment !== EXPECTED_CONTRACT_COMMITMENT ||
    verification.value.claim_path !== beacon.global_claim_path ||
    verification.value.client !== beacon.client ||
    verification.value.independently_verified_relays !== 2 ||
    verification.value.fields_equal !== true ||
    !/^[0-9a-f]{64}$/.test(verification.value.claim_sha256 || "") ||
    typeof verification.value.completed_at !== "string" ||
    Number.isNaN(Date.parse(verification.value.completed_at)) ||
    stableStringify(verification.value.chain) !==
      stableStringify({
        chainHash: beacon.chain_hash,
        publicKey: beacon.public_key,
        scheme: beacon.scheme,
        genesis_unix: beacon.genesis_unix,
        period_seconds: beacon.period_seconds
      })
  ) {
    throw new Error("beacon verification receipt is not bound to the frozen protocol")
  }

  if (authority === "initial") {
    verifyInitialAuthority(loaded, resolvedBundleRoot, verification.value)
  }

  const relayDocuments = [relayA.value, relayB.value]

  const expectedRequests = beacon.relays.flatMap(relay => [
    `${relay}/${beacon.chain_hash}/info`,
    `${relay}${beacon.path}`
  ])
  const observations = verification.value.network_observations

  if (
    !Array.isArray(observations) ||
    observations.length !== 4 ||
    stableStringify(observations.map(observation => observation.requested).sort()) !==
      stableStringify([...expectedRequests].sort()) ||
    observations.some(
      observation =>
        observation.response_url !== observation.requested ||
        !Number.isInteger(observation.status) ||
        observation.status < 200 ||
        observation.status >= 300
    )
  ) {
    throw new Error("beacon verification receipt has an invalid request trace")
  }

  if (stableStringify(verification.value.results) !== stableStringify(relayDocuments)) {
    throw new Error("beacon verification receipt does not bind the relay documents")
  }

  const expectedInfo = expectedChainInfo(beacon)
  const expectedRelays = beacon.relays
  const offlineFields = []

  for (let index = 0; index < relayDocuments.length; index += 1) {
    const document = relayDocuments[index]
    const relay = expectedRelays[index]
    const chainUrl = `${relay}/${beacon.chain_hash}`
    const infoUrl = `${chainUrl}/info`
    const beaconUrl = `${relay}${beacon.path}`

    if (
      document.schema !== "elara.exp003.drand-relay-evidence.v8" ||
      document.relay !== relay ||
      document.chain_url !== chainUrl ||
      document.info_url !== infoUrl ||
      document.beacon_url !== beaconUrl ||
      typeof document.acquired_at !== "string" ||
      Number.isNaN(Date.parse(document.acquired_at))
    ) {
      throw new Error("relay evidence URL or acquisition contract mismatch")
    }

    const info = exactChainInfo(document.chain_info, expectedInfo)
    const fields = selectedBeaconFields(document.beacon)
    offlineFields.push(await verifyBeaconOffline(clientLibrary, info, fields, beacon.round))
  }

  if (stableStringify(offlineFields[0]) !== stableStringify(offlineFields[1])) {
    throw new Error("independently verified relay responses differ")
  }

  const fields = offlineFields[0]

  if (
    fields.round !== beacon.round ||
    sha256(Buffer.from(fields.signature, "hex")) !== fields.randomness
  ) {
    throw new Error("verified beacon fields do not match the committed round")
  }

  const expectedVerified = {
    schema: "elara.exp003.verified-beacon.v8",
    mode: "confirmatory",
    confirmatory: true,
    verified: true,
    verification_method: beacon.verification_method,
    network: beacon.network,
    chain_hash: beacon.chain_hash,
    public_key: beacon.public_key,
    scheme: beacon.scheme,
    round: fields.round,
    randomness: fields.randomness,
    signature: fields.signature,
    previous_signature: fields.previous_signature,
    client: beacon.client,
    relay_count: 2,
    contract_commitment: EXPECTED_CONTRACT_COMMITMENT,
    verification_sha256: expectedVerificationSha256
  }

  if (stableStringify(verified.value) !== stableStringify(expectedVerified)) {
    throw new Error("verified beacon summary is not derivable from the complete verification bundle")
  }

  return {
    bundle_root: resolvedBundleRoot,
    verification_sha256: expectedVerificationSha256,
    verified_sha256: sha256(verified.bytes),
    verified: verified.value,
    files: Object.fromEntries(
      OUTPUT_FILES.map(relative => [relative, sha256(fs.readFileSync(path.join(resolvedBundleRoot, relative)))])
    )
  }
}

function fsyncDirectory(pathname) {
  const descriptor = fs.openSync(pathname, "r")

  try {
    fs.fsyncSync(descriptor)
  } finally {
    fs.closeSync(descriptor)
  }
}

function writeExclusiveFsync(pathname, bytes) {
  const descriptor = fs.openSync(pathname, "wx", 0o600)

  try {
    fs.writeFileSync(descriptor, bytes)
    fs.fsyncSync(descriptor)
  } finally {
    fs.closeSync(descriptor)
  }
}

function ensureDirectoryDurable(target) {
  const missing = []
  let cursor = target

  while (!fs.existsSync(cursor)) {
    missing.unshift(cursor)
    const parent = path.dirname(cursor)

    if (parent === cursor) {
      throw new Error(`no existing ancestor for durable directory: ${target}`)
    }

    cursor = parent
  }

  if (!fs.statSync(cursor).isDirectory()) {
    throw new Error(`durable directory ancestor is not a directory: ${cursor}`)
  }

  for (const directory of missing) {
    try {
      fs.mkdirSync(directory, { mode: 0o700 })
    } catch (error) {
      if (error.code !== "EEXIST" || !fs.statSync(directory).isDirectory()) {
        throw error
      }
    }

    fsyncDirectory(path.dirname(directory))
    fsyncDirectory(directory)
  }
}

function createPermanentClaim(claimPath, claim) {
  const parent = path.dirname(claimPath)
  ensureDirectoryDurable(parent)
  fsyncDirectory(parent)
  writeExclusiveFsync(claimPath, canonicalJsonBytes(claim))
  fsyncDirectory(parent)
  return sha256(fs.readFileSync(claimPath))
}

function accountHome() {
  const homedir = os.userInfo().homedir

  if (!path.isAbsolute(homedir)) {
    throw new Error("OS account home directory is not absolute")
  }

  return homedir
}

function fixedClaimPath() {
  return path.join(accountHome(), GLOBAL_CLAIM_ACCOUNT_RELATIVE)
}

function installSecureFetch(beacon) {
  const nativeFetch = globalThis.fetch
  const expected = new Set(
    beacon.relays.flatMap(relay => [
      `${relay}/${beacon.chain_hash}/info`,
      `${relay}${beacon.path}`
    ])
  )
  const observations = []

  globalThis.fetch = async (input, options = {}) => {
    const requested = typeof input === "string" ? input : input.url

    if (!expected.has(requested)) {
      throw new Error(`unexpected or non-chain-qualified drand URL: ${requested}`)
    }

    const response = await nativeFetch(input, { ...options, redirect: "manual" })

    if (response.status >= 300 && response.status < 400) {
      throw new Error(`drand redirect rejected: ${requested}`)
    }

    if (response.url !== requested) {
      throw new Error(`drand response origin/path changed: ${requested} -> ${response.url}`)
    }

    observations.push({ requested, response_url: response.url, status: response.status })
    return response
  }

  return {
    observations,
    restore: () => {
      globalThis.fetch = nativeFetch
    }
  }
}

async function fetchRelay(clientLibrary, beacon, relay) {
  const chainUrl = `${relay}/${beacon.chain_hash}`
  const infoUrl = `${chainUrl}/info`
  const beaconUrl = `${relay}${beacon.path}`
  const options = {
    ...clientLibrary.defaultChainOptions,
    chainVerificationParams: {
      chainHash: beacon.chain_hash,
      publicKey: beacon.public_key
    },
    noCache: false
  }
  const chain = new clientLibrary.HttpCachingChain(chainUrl, options)
  const info = exactChainInfo(await chain.info(), expectedChainInfo(beacon))
  const client = new clientLibrary.HttpChainClient(chain, options)
  const result = selectedBeaconFields(await clientLibrary.fetchBeacon(client, beacon.round))

  return {
    schema: "elara.exp003.drand-relay-evidence.v8",
    relay,
    chain_url: chainUrl,
    info_url: infoUrl,
    beacon_url: beaconUrl,
    acquired_at: new Date().toISOString(),
    chain_info: info,
    beacon: result
  }
}

function beginFetchAttempt(expectedProtocolSha256) {
  assertCleanNodeEnvironment()

  if (Math.floor(Date.now() / 1000) < EXPECTED_NOMINAL_UNIX) {
    throw new Error("committed drand round is not nominally available yet")
  }

  const claimPath = fixedClaimPath()
  const claim = {
    schema: "elara.exp003.beacon-fetch-claim.v8",
    protocol_sha256: expectedProtocolSha256,
    contract_commitment: EXPECTED_CONTRACT_COMMITMENT,
    round: EXPECTED_ROUND,
    canonical_output_root: EXPECTED_CANONICAL_OUTPUT_ROOT,
    claimed_at: new Date().toISOString()
  }

  return {
    claimPath,
    claimSha256: createPermanentClaim(claimPath, claim)
  }
}

async function fetchAndPersist(loaded, attempt) {
  const { protocol, protocolSha256, repoRoot } = loaded
  const beacon = protocol.beacon
  validateProtocolBeacon(beacon)
  const clientLibrary = loadFrozenClient(repoRoot, protocol)

  const outputRoot = resolveRepositoryPath(repoRoot, beacon.canonical_output_root, "beacon output root")
  const temporaryRoot = `${outputRoot}.tmp`
  const parent = path.dirname(outputRoot)

  if (!fs.statSync(parent).isDirectory()) {
    throw new Error("canonical beacon output parent is not a directory")
  }

  if (fs.existsSync(outputRoot) || fs.existsSync(temporaryRoot)) {
    throw new Error("canonical beacon output path is not absent")
  }

  const network = installSecureFetch(beacon)

  try {
    const settled = await Promise.allSettled(
      beacon.relays.map(relay => fetchRelay(clientLibrary, beacon, relay))
    )

    if (settled.some(result => result.status === "rejected")) {
      const failures = settled
        .filter(result => result.status === "rejected")
        .map(result => result.reason?.stack || String(result.reason))
      throw new Error(`one or more pinned relay attempts failed: ${failures.join(" | ")}`)
    }

    const results = settled.map(result => result.value)
    const first = selectedBeaconFields(results[0].beacon)
    const second = selectedBeaconFields(results[1].beacon)

    if (stableStringify(first) !== stableStringify(second)) {
      throw new Error("independently verified relay responses differ")
    }

    if (
      first.round !== beacon.round ||
      sha256(Buffer.from(first.signature, "hex")) !== first.randomness
    ) {
      throw new Error("verified beacon fields do not match the committed round")
    }

    const expectedRequests = new Set(
      beacon.relays.flatMap(relay => [
        `${relay}/${beacon.chain_hash}/info`,
        `${relay}${beacon.path}`
      ])
    )

    if (
      network.observations.length !== 4 ||
      network.observations.some(observation => !expectedRequests.has(observation.requested)) ||
      new Set(network.observations.map(observation => observation.requested)).size !== 4
    ) {
      throw new Error("drand request trace is not the exact two-relay info/beacon frame")
    }

    const verificationBase = {
      schema: "elara.exp003.beacon-verification.v8",
      protocol_sha256: protocolSha256,
      contract_commitment: EXPECTED_CONTRACT_COMMITMENT,
      claim_path: beacon.global_claim_path,
      claim_sha256: attempt.claimSha256,
      chain: {
        chainHash: beacon.chain_hash,
        publicKey: beacon.public_key,
        scheme: beacon.scheme,
        genesis_unix: beacon.genesis_unix,
        period_seconds: beacon.period_seconds
      },
      client: beacon.client,
      independently_verified_relays: results.length,
      fields_equal: true,
      network_observations: network.observations,
      completed_at: new Date().toISOString(),
      results
    }
    const verificationBytes = canonicalJsonBytes(verificationBase)
    const verificationSha256 = sha256(verificationBytes)
    const verified = {
      schema: "elara.exp003.verified-beacon.v8",
      mode: "confirmatory",
      confirmatory: true,
      verified: true,
      verification_method: beacon.verification_method,
      network: beacon.network,
      chain_hash: beacon.chain_hash,
      public_key: beacon.public_key,
      scheme: beacon.scheme,
      round: first.round,
      randomness: first.randomness,
      signature: first.signature,
      previous_signature: first.previous_signature,
      client: beacon.client,
      relay_count: results.length,
      contract_commitment: EXPECTED_CONTRACT_COMMITMENT,
      verification_sha256: verificationSha256
    }

    fs.mkdirSync(temporaryRoot, { recursive: false, mode: 0o700 })
    writeExclusiveFsync(path.join(temporaryRoot, "api.drand.sh.json"), canonicalJsonBytes(results[0]))
    writeExclusiveFsync(
      path.join(temporaryRoot, "drand.cloudflare.com.json"),
      canonicalJsonBytes(results[1])
    )
    writeExclusiveFsync(path.join(temporaryRoot, "verification.json"), verificationBytes)
    writeExclusiveFsync(path.join(temporaryRoot, "verified.json"), canonicalJsonBytes(verified))
    fsyncDirectory(temporaryRoot)
    fsyncDirectory(parent)
    fs.renameSync(temporaryRoot, outputRoot)
    fsyncDirectory(parent)

    const result = await verifyBundle(loaded, outputRoot, verificationSha256, "initial")
    process.stdout.write(`${stableStringify(result)}\n`)
  } finally {
    network.restore()
  }
}

function usageError() {
  return new Error(
    "usage: node fetch-and-verify.cjs fetch <protocol.json> <protocol-sha256> OR " +
      "node fetch-and-verify.cjs verify <protocol.json> <protocol-sha256> " +
      "<canonical-beacon-bundle-root> <verification-sha256> OR " +
      "node fetch-and-verify.cjs verify-copy <protocol.json> <protocol-sha256> " +
      "<copied-beacon-bundle-root> <verification-sha256>"
  )
}

async function main() {
  const [mode, protocolPath, expectedProtocolSha256, bundleRoot, expectedVerificationSha256] =
    process.argv.slice(2)

  if (mode === "fetch" && protocolPath && expectedProtocolSha256) {
    const attempt = beginFetchAttempt(expectedProtocolSha256)

    if (bundleRoot || expectedVerificationSha256) {
      throw usageError()
    }

    await fetchAndPersist(loadProtocol(protocolPath, expectedProtocolSha256), attempt)
    return
  }

  if (
    (mode === "verify" || mode === "verify-copy") &&
    protocolPath &&
    expectedProtocolSha256 &&
    bundleRoot &&
    expectedVerificationSha256
  ) {
    const result = await verifyBundle(
      loadProtocol(protocolPath, expectedProtocolSha256),
      bundleRoot,
      expectedVerificationSha256,
      mode === "verify" ? "initial" : "copy"
    )
    process.stdout.write(`${stableStringify(result)}\n`)
    return
  }

  throw usageError()
}

module.exports = {
  EXPECTED_CONTRACT_COMMITMENT,
  accountHome,
  assertCleanNodeEnvironment,
  beginFetchAttempt,
  contractCommitment,
  createPermanentClaim,
  fixedClaimPath,
  semanticProjection,
  stableStringify,
  verifyBeaconOffline,
  verifyPermanentClaim,
  verifyRuntimeClosure
}

if (require.main === module) {
  main().catch(error => {
    process.stderr.write(`${error.stack || error}\n`)
    process.exitCode = 1
  })
}

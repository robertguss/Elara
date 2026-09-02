const fetch = require("isomorphic-fetch")
const AbortController = require("abort-controller")

global.fetch = fetch
global.AbortController = AbortController

const {
  defaultChainOptions,
  fetchBeacon,
  HttpCachingChain,
  HttpChainClient
} = require("drand-client")

const round = 6429446
const expected = {
  chainHash: "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce",
  publicKey: "868f005eb8e6e4ca0a47c8a77ceaa5309a47978a7c71bc5cce96366b5d7a569937c529eeda66c7293784a9402801af31"
}
const options = {
  ...defaultChainOptions,
  chainVerificationParams: expected,
  noCache: true
}

async function verify(url) {
  const chain = new HttpCachingChain(url, options)
  const client = new HttpChainClient(chain, options)
  const beacon = await fetchBeacon(client, round)

  return {
    url,
    round: beacon.round,
    randomness: beacon.randomness,
    signature: beacon.signature,
    previous_signature: beacon.previous_signature
  }
}

Promise.all([
  verify("https://api.drand.sh"),
  verify("https://drand.cloudflare.com")
])
  .then(results => {
    const fields = ["round", "randomness", "signature", "previous_signature"]

    if (JSON.stringify(results[0], fields) !== JSON.stringify(results[1], fields)) {
      throw new Error("verified relay responses differ")
    }

    console.log(JSON.stringify({
      verified: true,
      client: "drand-client@1.4.2",
      chain: expected,
      results
    }, null, 2))
  })
  .catch(error => {
    console.error(error)
    process.exit(1)
  })

defmodule Elara.Benchmark.PreregistrationV8Test do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.Exp003.Materializer

  @root Path.expand("../../..", __DIR__)
  @protocol_path Path.join(
                   @root,
                   "docs/experiments/003-effect-receipt-v8-protocol.json"
                 )
  @preregistration_path Path.join(
                          @root,
                          "docs/experiments/003-effect-receipt-confirmatory-preregistration-v8.md"
                        )
  @pre_beacon_path Path.join(
                     @root,
                     "docs/experiments/003-effect-receipt-v8-pre-beacon-qualification.json"
                   )
  @boundary_qualification_path Path.join(
                                 @root,
                                 "docs/experiments/003-effect-receipt-v8-boundary-qualification.json"
                               )
  @boundary_protocol_path Path.join(
                            @root,
                            "test/fixtures/benchmark/exp003-v8-boundary/protocol.json"
                          )
  @v7_protocol_path Path.join(
                      @root,
                      "docs/experiments/003-effect-receipt-v7-protocol.json"
                    )
  @eligible ~w(P01 P02 P04 P06 P07 P08 S01 S02 S03 S04 W01 W02 W03 W05 W06 W07 W08)
  @excluded ~w(P03 P05 W04)

  setup_all do
    %{
      protocol: read_json(@protocol_path),
      preregistration: File.read!(@preregistration_path),
      pre_beacon: read_json(@pre_beacon_path),
      boundary_qualification: read_json(@boundary_qualification_path),
      boundary_protocol: read_json(@boundary_protocol_path),
      v7: read_json(@v7_protocol_path)
    }
  end

  test "freezes the pushed explicit stack and its pre-beacon qualification", context do
    %{
      protocol: protocol,
      pre_beacon: report,
      boundary_qualification: boundary_report,
      boundary_protocol: boundary_protocol
    } = context

    proof = protocol["pre_beacon_qualification"]
    boundary = proof["beacon_boundary_requalification"]

    assert protocol["schema"] == "elara.exp003.materialization-protocol.v8"
    assert protocol["preregistration_version"] == "ER-3/FND-2-v8"
    assert protocol["mode"] == "confirmatory"
    assert protocol["frozen_against_commit"] == "f4503a92a9f400ee8cb39960d53c939d2df7b932"
    assert proof["implementation_commit"] == "35be3015c56a01350bcb08ba6dde464fda3be3bf"
    assert proof["roadmap_transition_commit"] == protocol["frozen_against_commit"]
    assert identity_sha256(proof["report"]) == proof["report"]["sha256"]
    assert proof["report"]["size_bytes"] == File.stat!(@pre_beacon_path).size

    assert identity_sha256(proof["development_protocol"]) ==
             proof["development_protocol"]["sha256"]

    assert identity_sha256(proof["development_beacon"]) ==
             proof["development_beacon"]["sha256"]

    assert proof["candidate_construction_count"] == 20
    assert proof["eligible_candidate_count"] == 17
    assert proof["selected_task_count"] == 12
    assert proof["selected_row_count"] == 20
    assert proof["fault_run_count"] == 72
    assert proof["no_fault_run_count"] == 72
    assert proof["checkpoint_event_count"] == 288
    assert proof["score_status"] == "Pass"
    assert proof["replay_status"] == "Pass"
    assert proof["oracle_verdict"] == "GO"

    changed_boundary_paths = [
      "lib/elara/benchmark/exp003/materializer.ex",
      "priv/benchmark/materialize_exp003_v8.exs"
    ]

    assert Map.drop(protocol["source_identities"], changed_boundary_paths) ==
             Map.drop(report["source_identities"], changed_boundary_paths)

    assert protocol["command_stack"]["source_paths"] == report["command_stack"]["source_paths"]

    assert identity_sha256(boundary["development_protocol"]) ==
             boundary["development_protocol"]["sha256"]

    assert identity_sha256(boundary["report"]) == boundary["report"]["sha256"]
    assert boundary["report"]["size_bytes"] == File.stat!(@boundary_qualification_path).size
    assert boundary_protocol["source_identities"] == protocol["source_identities"]
    assert boundary_report["source_identities"] == protocol["source_identities"]
    assert get_in(boundary_report, ["summary", "candidate_construction_count"]) == 20
    assert get_in(boundary_report, ["summary", "qualification_fault_run_count"]) == 72
    assert get_in(boundary_report, ["summary", "qualification_no_fault_run_count"]) == 72
    assert get_in(boundary_report, ["summary", "qualification_status"]) == "Pass"
    assert get_in(boundary_report, ["summary", "replay_status"]) == "Pass"

    for {path, expected} <- protocol["source_identities"] do
      assert file_sha256(path) == expected
    end
  end

  test "commits an exact future round without fetching or selecting it", context do
    %{protocol: protocol, preregistration: preregistration} = context
    beacon = protocol["beacon"]
    exposure = protocol["exposure"]

    assert beacon["chain_hash"] ==
             "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"

    assert beacon["public_key"] ==
             "868f005eb8e6e4ca0a47c8a77ceaa5309a47978a7c71bc5cce96366b5d7a569937c529eeda66c7293784a9402801af31"

    assert beacon["scheme"] == "pedersen-bls-chained"
    assert beacon["round"] == 6_430_646
    assert beacon["nominal_unix"] == 1_788_350_400
    assert beacon["nominal_time"] == "2026-09-02T12:00:00Z"

    assert beacon["genesis_unix"] + (beacon["round"] - 1) * beacon["period_seconds"] ==
             beacon["nominal_unix"]

    assert beacon["nominal_unix"] > commit_unix(protocol["frozen_against_commit"])
    assert beacon["relays"] == ["https://api.drand.sh", "https://drand.cloudflare.com"]
    assert beacon["client"] == "drand-client@1.4.2"
    assert beacon["early_fetch"] == "forbidden"
    assert beacon["substitution_or_retry"] == "forbidden"
    assert protocol["seed"]["domain_separator"] == "elara:exp-003:er3:fnd-2:v8\\0"
    assert protocol["seed"]["commitment"] == protocol["frozen_against_commit"]
    assert preregistration =~ "1595431050 + (6430646 - 1) * 30 = 1788350400"
    assert preregistration =~ "must not invoke the verifier before nominal time"

    assert exposure == %{
             "B_or_T_calculated" => false,
             "dogfood_runs" => 0,
             "external_fault_runs" => 0,
             "future_beacon_committed" => true,
             "future_beacon_fetched" => false,
             "held_out_literals_generated" => false,
             "held_out_selection_performed" => false,
             "target_fault_runs" => 0,
             "target_timing_runs" => 0
           }

    bytes = File.read!(@protocol_path)
    refute bytes =~ ~r/"randomness"\s*:\s*"[0-9a-f]{64}"/
    refute bytes =~ ~r/"signature"\s*:\s*"[0-9a-f]+"/
    refute bytes =~ ~r/"sha256"\s*:\s*"[0-9a-f]{64}".*"round"/s
  end

  test "pins an independently verifiable no-retry beacon command", %{protocol: protocol} do
    beacon = protocol["beacon"]
    source = beacon["verification_source"]
    package = beacon["verification_package"]
    source_bytes = File.read!(Path.join(@root, source["path"]))
    lock = read_json(Path.join(@root, package["lock_path"]))

    assert identity_sha256(source) == source["sha256"]
    assert identity_sha256(package) == package["sha256"]
    assert file_sha256(package["lock_path"]) == package["lock_sha256"]
    assert get_in(lock, ["packages", "node_modules/drand-client", "version"]) == "1.4.2"
    assert get_in(lock, ["packages", "node_modules/drand-client", "integrity"]) =~ "sha512-"
    assert source_bytes =~ "defaultChainOptions"
    assert source_bytes =~ "chainVerificationParams"
    assert source_bytes =~ "fetchBeacon(client, beacon.round)"
    assert source_bytes =~ "disableBeaconVerification: false"
    assert source_bytes =~ "Promise.allSettled"
    assert source_bytes =~ "independently verified relay responses differ"
    assert source_bytes =~ "committed drand round is not nominally available yet"
    assert source_bytes =~ "protocol digest mismatch"
    assert source_bytes =~ "canonical beacon output path is not absent"
    assert source_bytes =~ "NODE_OPTIONS must be unset"
    assert source_bytes =~ "redirect: \"manual\""
    assert source_bytes =~ "createPermanentClaim"
    assert source_bytes =~ "verifyBeaconOffline"

    assert beacon["verification_output_paths"] ==
             ~w(api.drand.sh.json drand.cloudflare.com.json verification.json verified.json)

    {output, status} =
      System.cmd("node", ["--check", source["path"]], cd: @root, stderr_to_stdout: true)

    assert status == 0, output
  end

  test "anchors one semantic contract in both verifier boundaries", %{protocol: protocol} do
    source = get_in(protocol, ["beacon", "verification_source", "path"])
    expected = get_in(protocol, ["contract_commitment", "sha256"])

    script = """
    const verifier = require(process.argv[1])
    const protocol = require(process.argv[2])
    process.stdout.write(verifier.contractCommitment(protocol))
    """

    {output, 0} =
      System.cmd(
        "node",
        ["-e", script, Path.join(@root, source), @protocol_path],
        cd: @root,
        env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
        stderr_to_stdout: true
      )

    assert output == expected
    assert file_sha256(source) == get_in(protocol, ["beacon", "verification_source", "sha256"])
    assert File.read!(Path.join(@root, source)) =~ expected
    assert File.read!(Path.join(@root, "lib/elara/benchmark/exp003/materializer.ex")) =~ expected
  end

  test "rejects preloaded Node environments and a mutated loaded dependency", %{
    protocol: protocol
  } do
    source = get_in(protocol, ["beacon", "verification_source", "path"])

    environment_script = """
    const verifier = require(process.argv[1])
    try {
      verifier.assertCleanNodeEnvironment()
    } catch (error) {
      process.stderr.write(String(error.message))
      process.exit(2)
    }
    """

    {output, status} =
      System.cmd(
        "node",
        ["-e", environment_script, Path.join(@root, source)],
        cd: @root,
        env: [{"NODE_OPTIONS", "--trace-warnings"}, {"NODE_PATH", nil}],
        stderr_to_stdout: true
      )

    assert status == 2
    assert output =~ "NODE_OPTIONS must be unset"

    temporary_root = temporary_root("elara-v8-runtime")
    on_exit(fn -> File.rm_rf(temporary_root) end)

    manifest =
      read_json(Path.join(@root, get_in(protocol, ["beacon", "runtime_dependencies", "path"])))

    Enum.each(manifest["files"], fn identity ->
      source_path = Path.join(@root, "priv/benchmark/exp003-v8-beacon/#{identity["path"]}")
      destination = Path.join(temporary_root, identity["path"])
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source_path, destination)
    end)

    manifest_path = Path.join(temporary_root, "manifest.json")
    File.write!(manifest_path, JSON.encode!(manifest))

    closure_script = """
    const fs = require('node:fs')
    const verifier = require(process.argv[1])
    const manifest = JSON.parse(fs.readFileSync(process.argv[3]))
    try {
      verifier.verifyRuntimeClosure(process.argv[2], manifest)
    } catch (error) {
      process.stderr.write(String(error.message))
      process.exit(2)
    }
    """

    assert {_, 0} =
             System.cmd(
               "node",
               [
                 "-e",
                 closure_script,
                 Path.join(@root, source),
                 temporary_root,
                 manifest_path
               ],
               cd: @root,
               env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
               stderr_to_stdout: true
             )

    client_path = Path.join(temporary_root, hd(manifest["files"])["path"])
    File.write!(client_path, "\n// mutation\n", [:append])

    {mutation_output, mutation_status} =
      System.cmd(
        "node",
        [
          "-e",
          closure_script,
          Path.join(@root, source),
          temporary_root,
          manifest_path
        ],
        cd: @root,
        env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
        stderr_to_stdout: true
      )

    assert mutation_status == 2
    assert mutation_output =~ "runtime dependency shape mismatch"
  end

  test "the permanent claim permits one winner and forbids retry or alternate output roots", %{
    protocol: protocol
  } do
    temporary_root = temporary_root("elara-v8-claim")
    claim_path = Path.join(temporary_root, "missing/parent/claim.json")
    source = Path.join(@root, get_in(protocol, ["beacon", "verification_source", "path"]))
    on_exit(fn -> File.rm_rf(temporary_root) end)

    claim_script = """
    const verifier = require(process.argv[1])
    try {
      verifier.createPermanentClaim(process.argv[2], {schema: 'claim-test'})
    } catch (error) {
      if (error.code === 'EEXIST') process.exit(3)
      throw error
    }
    """

    attempts =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          System.cmd("node", ["-e", claim_script, source, claim_path],
            cd: @root,
            env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
            stderr_to_stdout: true
          )
        end)
      end)
      |> Task.await_many(10_000)

    assert attempts |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [0, 3]
    assert File.exists?(claim_path)
    assert File.dir?(Path.dirname(claim_path))

    assert {_, 3} =
             System.cmd("node", ["-e", claim_script, source, claim_path],
               cd: @root,
               env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
               stderr_to_stdout: true
             )
  end

  test "fixes the claim under the OS account home and validates its binding", %{
    protocol: protocol
  } do
    temporary_root = temporary_root("elara-v8-claim-binding")
    claim_path = Path.join(temporary_root, "claim.json")
    source = Path.join(@root, get_in(protocol, ["beacon", "verification_source", "path"]))
    protocol_sha256 = file_sha256("docs/experiments/003-effect-receipt-v8-protocol.json")
    on_exit(fn -> File.rm_rf(temporary_root) end)

    script = """
    const crypto = require('node:crypto')
    const verifier = require(process.argv[1])
    const claimPath = process.argv[2]
    const protocolSha256 = process.argv[3]
    const claim = {
      schema: 'elara.exp003.beacon-fetch-claim.v8',
      protocol_sha256: protocolSha256,
      contract_commitment: verifier.EXPECTED_CONTRACT_COMMITMENT,
      round: 6430646,
      canonical_output_root: 'test/fixtures/benchmark/exp003-v8-beacon',
      claimed_at: '2026-09-02T12:00:00.000Z'
    }
    verifier.createPermanentClaim(claimPath, claim)
    const claimSha256 = crypto.createHash('sha256').update(`${verifier.stableStringify(claim)}\n`).digest('hex')
    verifier.verifyPermanentClaim(claimPath, {claim_sha256: claimSha256}, {protocolSha256})
    process.stdout.write(JSON.stringify({home: verifier.accountHome(), fixed: verifier.fixedClaimPath()}))
    """

    {output, 0} =
      System.cmd("node", ["-e", script, source, claim_path, protocol_sha256],
        cd: @root,
        env: [
          {"HOME", Path.join(temporary_root, "caller-controlled-home")},
          {"NODE_OPTIONS", nil},
          {"NODE_PATH", nil}
        ],
        stderr_to_stdout: true
      )

    locations = JSON.decode!(output)
    refute locations["home"] == Path.join(temporary_root, "caller-controlled-home")

    assert locations["fixed"] ==
             Path.join(locations["home"], ".elara/benchmark/exp003/v8/beacon-fetch.claim.json")

    missing_script = """
    const verifier = require(process.argv[1])
    try {
      verifier.verifyPermanentClaim(process.argv[2], {claim_sha256: '#{String.duplicate("0", 64)}'}, {protocolSha256: process.argv[3]})
    } catch (error) {
      process.stderr.write(String(error.message))
      process.exit(2)
    }
    """

    assert {mismatch_output, 2} =
             System.cmd("node", ["-e", missing_script, source, claim_path, protocol_sha256],
               cd: @root,
               env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
               stderr_to_stdout: true
             )

    assert mismatch_output =~ "permanent beacon claim digest mismatch"

    File.rm!(claim_path)

    assert {missing_output, 2} =
             System.cmd("node", ["-e", missing_script, source, claim_path, protocol_sha256],
               cd: @root,
               env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
               stderr_to_stdout: true
             )

    assert missing_output =~ "ENOENT"
  end

  test "a consumed claim survives later validation failure and makes retry impossible", %{
    protocol: protocol
  } do
    temporary_root = temporary_root("elara-v8-dirty-attempt")
    claim_path = Path.join(temporary_root, "claim.json")
    dependency_path = Path.join(temporary_root, "dependency.cjs")
    source = Path.join(@root, get_in(protocol, ["beacon", "verification_source", "path"]))
    File.write!(dependency_path, "module.exports = true\n", [:exclusive])
    on_exit(fn -> File.rm_rf(temporary_root) end)

    script = """
    const fs = require('node:fs')
    const verifier = require(process.argv[1])
    const claimPath = process.argv[2]
    const dependencyPath = process.argv[3]
    try {
      verifier.createPermanentClaim(claimPath, {schema: 'attempt-consumed'})
      if (fs.readFileSync(dependencyPath, 'utf8') !== 'expected') throw new Error('dirty dependency')
    } catch (error) {
      process.stderr.write(`${error.code || 'ERROR'}:${error.message}`)
      process.exit(2)
    }
    """

    assert {dirty_output, 2} =
             System.cmd("node", ["-e", script, source, claim_path, dependency_path],
               cd: @root,
               env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
               stderr_to_stdout: true
             )

    assert dirty_output =~ "dirty dependency"
    assert File.exists?(claim_path)

    assert {retry_output, 2} =
             System.cmd("node", ["-e", script, source, claim_path, dependency_path],
               cd: @root,
               env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
               stderr_to_stdout: true
             )

    assert retry_output =~ "EEXIST"
  end

  test "fetch consumes its permanent claim before caller-controlled validation", %{
    protocol: protocol
  } do
    source = Path.join(@root, get_in(protocol, ["beacon", "verification_source", "path"]))
    bytes = File.read!(source)
    {main_start, _} = :binary.match(bytes, "async function main()")
    main = binary_part(bytes, main_start, byte_size(bytes) - main_start)
    {claim_offset, _} = :binary.match(main, "beginFetchAttempt")
    {protocol_offset, _} = :binary.match(main, "loadProtocol")
    {output_argument_offset, _} = :binary.match(main, "bundleRoot || expectedVerificationSha256")

    assert claim_offset < protocol_offset
    assert claim_offset < output_argument_offset
  end

  test "the materializer rejects arbitrary randomness and a caller-redigested protocol", %{
    protocol: protocol
  } do
    temporary_root = temporary_root("elara-v8-forgery")
    bundle_root = Path.join(temporary_root, "beacon")
    output_root = Path.join(temporary_root, "materialized")
    source = get_in(protocol, ["beacon", "verification_source", "path"])
    File.mkdir!(bundle_root)
    on_exit(fn -> File.rm_rf(temporary_root) end)

    verification_sha256 = write_forged_beacon_bundle!(bundle_root, protocol)
    protocol_sha256 = file_sha256("docs/experiments/003-effect-receipt-v8-protocol.json")

    {verification_output, verification_status} =
      System.cmd(
        "node",
        [
          source,
          "verify-copy",
          @protocol_path,
          protocol_sha256,
          bundle_root,
          verification_sha256
        ],
        cd: @root,
        env: [{"NODE_OPTIONS", nil}, {"NODE_PATH", nil}],
        stderr_to_stdout: true
      )

    assert verification_status != 0
    assert verification_output =~ "offline drand BLS verification failed"

    assert {:error, error} =
             Materializer.run(
               @root,
               @protocol_path,
               protocol_sha256,
               bundle_root,
               verification_sha256,
               output_root
             )

    assert error =~ "noncanonical_initial_beacon_root"
    refute File.exists?(output_root)

    modified = put_in(protocol, ["beacon", "round"], protocol["beacon"]["round"] + 1)
    modified_path = Path.join(temporary_root, "modified-protocol.json")
    modified_bytes = JSON.encode!(modified)
    File.write!(modified_path, modified_bytes)

    assert {:error, modified_error} =
             Materializer.run(
               @root,
               modified_path,
               sha256(modified_bytes),
               bundle_root,
               verification_sha256,
               output_root
             )

    assert modified_error =~ "protocol_semantic_commitment"
    refute File.exists?(output_root)
  end

  test "carries the V7 semantic contract forward without result-conditioned changes", context do
    %{protocol: protocol, v7: v7} = context

    for key <- [
          "required_evidence_fields",
          "candidate_sampling",
          "provider_and_identity_contract",
          "workspace_and_causality_contract",
          "fault_contracts",
          "execution_schedule",
          "scoring",
          "gate_3",
          "targets",
          "dogfood"
        ] do
      assert protocol[key] == v7[key], "semantic drift in #{key}"
    end

    assert length(protocol["required_evidence_fields"]) == 54

    assert protocol["candidate_frame"] == %{
             "eligible_count" => 17,
             "eligible_ids" => @eligible,
             "excluded_ids" => @excluded,
             "source_count" => 20
           }

    candidates = protocol["candidate_sampling"]["candidates"]
    assert sum_probabilities(candidates, "task_inclusion_probability") == {12, 1}
    assert sum_probabilities(candidates, "secondary_row_inclusion_probability") == {8, 1}

    assert protocol["scoring"]["material_improvement"] ==
             ["B >= 2", "B - T >= 2", "2 * (B - T) >= B"]

    assert hd(protocol["gate_3"]["precedence"]) == "Stop on invalidity or safety"

    refute get_in(protocol, [
             "targets",
             "external_comparator",
             "external_fault_execution_authorized"
           ])
  end

  test "freezes all identities, commands, schemas, and predecessor evidence", %{
    protocol: protocol
  } do
    assert Enum.sort(Map.keys(protocol["inputs"])) ==
             ~w(candidate_source command_path_report compatibility dogfood_source external_source)

    for {_name, identity} <- protocol["inputs"] do
      assert identity_sha256(identity) == identity["sha256"]
      assert read_json(Path.join(@root, identity["path"]))["schema"] == identity["schema"]
    end

    assert protocol["outputs"] == %{
             "beacon" => "beacon/verified.json",
             "beacon_api_drand" => "beacon/api.drand.sh.json",
             "beacon_cloudflare" => "beacon/drand.cloudflare.com.json",
             "beacon_verification" => "beacon/verification.json",
             "dogfood" => "dogfood-plan.json",
             "external" => "external-adapter-equivalence.json",
             "manifest" => "manifest.json",
             "receipt" => "materialization-receipt.json"
           }

    assert Map.keys(protocol["command_boundary"])
           |> Enum.sort() ==
             ~w(beacon_claim beacon_fetch beacon_verify beacon_verify_copy confirmatory_execute_only execute execution_claim failure_policy materialize qualification_authorization qualify replay)

    for {path, expected} <- protocol["preserved_artifact_sha256"] do
      assert file_sha256(path) == expected
    end

    assert File.exists?(@preregistration_path)
    assert File.exists?(@pre_beacon_path)
    assert protocol["invalidation"]["pre_result_amendment"] =~ "requires V9"
    assert protocol["invalidation"]["predecessors"] =~ "V1-V7 are immutable evidence"
  end

  test "the production materializer accepts the frozen protocol before beacon read" do
    temporary_root =
      Path.join(
        System.tmp_dir!(),
        "elara-v8-protocol-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(temporary_root)
    output_root = Path.join(temporary_root, "materialized")
    missing_beacon = Path.join(temporary_root, "not-fetched.json")

    on_exit(fn -> File.rm_rf(temporary_root) end)

    assert {:error, error} =
             Materializer.run(
               @root,
               @protocol_path,
               file_sha256("docs/experiments/003-effect-receipt-v8-protocol.json"),
               missing_beacon,
               String.duplicate("0", 64),
               output_root
             )

    assert error =~ "not-fetched.json"
    refute File.exists?(output_root)
    refute File.exists?(output_root <> ".tmp")
  end

  defp write_forged_beacon_bundle!(bundle_root, protocol) do
    beacon = protocol["beacon"]
    signature = String.duplicate("ab", 96)
    previous_signature = String.duplicate("cd", 96)
    randomness = signature |> Base.decode16!(case: :lower) |> sha256()
    acquired_at = "2026-09-02T12:00:01.000Z"

    chain_info = %{
      "public_key" => beacon["public_key"],
      "period" => beacon["period_seconds"],
      "genesis_time" => beacon["genesis_unix"],
      "hash" => beacon["chain_hash"],
      "groupHash" => beacon["group_hash"],
      "schemeID" => beacon["scheme"],
      "metadata" => %{"beaconID" => beacon["beacon_id"]}
    }

    fields = %{
      "round" => beacon["round"],
      "randomness" => randomness,
      "signature" => signature,
      "previous_signature" => previous_signature
    }

    results =
      Enum.map(beacon["relays"], fn relay ->
        %{
          "schema" => "elara.exp003.drand-relay-evidence.v8",
          "relay" => relay,
          "chain_url" => "#{relay}/#{beacon["chain_hash"]}",
          "info_url" => "#{relay}/#{beacon["chain_hash"]}/info",
          "beacon_url" => relay <> beacon["path"],
          "acquired_at" => acquired_at,
          "chain_info" => chain_info,
          "beacon" => fields
        }
      end)

    Enum.zip(~w(api.drand.sh.json drand.cloudflare.com.json), results)
    |> Enum.each(fn {relative, value} ->
      write_canonical_json!(Path.join(bundle_root, relative), value)
    end)

    network_observations =
      Enum.flat_map(beacon["relays"], fn relay ->
        [
          %{
            "requested" => "#{relay}/#{beacon["chain_hash"]}/info",
            "response_url" => "#{relay}/#{beacon["chain_hash"]}/info",
            "status" => 200
          },
          %{
            "requested" => relay <> beacon["path"],
            "response_url" => relay <> beacon["path"],
            "status" => 200
          }
        ]
      end)

    verification = %{
      "schema" => "elara.exp003.beacon-verification.v8",
      "protocol_sha256" => file_sha256("docs/experiments/003-effect-receipt-v8-protocol.json"),
      "contract_commitment" => get_in(protocol, ["contract_commitment", "sha256"]),
      "claim_path" => beacon["global_claim_path"],
      "claim_sha256" => String.duplicate("0", 64),
      "chain" => %{
        "chainHash" => beacon["chain_hash"],
        "publicKey" => beacon["public_key"],
        "scheme" => beacon["scheme"],
        "genesis_unix" => beacon["genesis_unix"],
        "period_seconds" => beacon["period_seconds"]
      },
      "client" => beacon["client"],
      "independently_verified_relays" => 2,
      "fields_equal" => true,
      "network_observations" => network_observations,
      "completed_at" => acquired_at,
      "results" => results
    }

    verification_path = Path.join(bundle_root, "verification.json")
    verification_bytes = write_canonical_json!(verification_path, verification)
    verification_sha256 = sha256(verification_bytes)

    write_canonical_json!(Path.join(bundle_root, "verified.json"), %{
      "schema" => "elara.exp003.verified-beacon.v8",
      "mode" => "confirmatory",
      "confirmatory" => true,
      "verified" => true,
      "verification_method" => beacon["verification_method"],
      "network" => beacon["network"],
      "chain_hash" => beacon["chain_hash"],
      "public_key" => beacon["public_key"],
      "scheme" => beacon["scheme"],
      "round" => beacon["round"],
      "randomness" => randomness,
      "signature" => signature,
      "previous_signature" => previous_signature,
      "client" => beacon["client"],
      "relay_count" => 2,
      "contract_commitment" => get_in(protocol, ["contract_commitment", "sha256"]),
      "verification_sha256" => verification_sha256
    })

    verification_sha256
  end

  defp write_canonical_json!(path, value) do
    bytes = Materializer.canonical_json(value) <> "\n"
    File.write!(path, bytes, [:exclusive])
    bytes
  end

  defp temporary_root(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
    )
    |> tap(&File.mkdir!/1)
  end

  defp read_json(path), do: path |> File.read!() |> JSON.decode!()

  defp identity_sha256(identity), do: file_sha256(identity["path"])

  defp file_sha256(path) do
    @root
    |> Path.join(path)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp commit_unix(commit) do
    {output, 0} = System.cmd("git", ["show", "-s", "--format=%ct", commit], cd: @root)
    output |> String.trim() |> String.to_integer()
  end

  defp sum_probabilities(candidates, key) do
    candidates
    |> Enum.map(&parse_fraction(&1[key]))
    |> Enum.reduce({0, 1}, &add_fraction/2)
  end

  defp parse_fraction(value) do
    case String.split(value, "/") do
      [numerator] -> {String.to_integer(numerator), 1}
      [numerator, denominator] -> {String.to_integer(numerator), String.to_integer(denominator)}
    end
  end

  defp add_fraction({left_n, left_d}, {right_n, right_d}) do
    numerator = left_n * right_d + right_n * left_d
    denominator = left_d * right_d
    divisor = Integer.gcd(numerator, denominator)
    {div(numerator, divisor), div(denominator, divisor)}
  end
end

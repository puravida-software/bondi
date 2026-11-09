module Docker = Bondi_server__Docker__Client

let unwrap = function
  | Ok v -> v
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)

let test_image_inspect_response_with_healthcheck_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "ContainerConfig": {
          "Healthcheck": {
            "Test": ["CMD-SHELL", "curl -f http://localhost:8080/health"]
          }
        }
      }|}
  in
  let response = Docker.image_inspect_response_of_yojson json |> unwrap in
  let cc = Option.get response.container_config in
  let healthcheck = cc.healthcheck in
  Alcotest.check Alcotest.bool "healthcheck is present" true
    (Option.is_some healthcheck);
  let hc = Option.get healthcheck in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "healthcheck test command"
    [ "CMD-SHELL"; "curl -f http://localhost:8080/health" ]
    hc.test

let test_image_inspect_response_without_healthcheck_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "ContainerConfig": {
          "Hostname": "abc123"
        }
      }|}
  in
  let response = Docker.image_inspect_response_of_yojson json |> unwrap in
  let cc = Option.get response.container_config in
  let healthcheck = cc.healthcheck in
  Alcotest.check Alcotest.bool "healthcheck is absent" false
    (Option.is_some healthcheck)

let test_inspect_state_with_health_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "Status": "running",
        "ExitCode": 0,
        "Health": {
          "Status": "healthy",
          "FailingStreak": 0,
          "Log": [
            {"Output": "OK\n", "ExitCode": 0}
          ]
        }
      }|}
  in
  let state = Docker.inspect_state_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "status" "running" state.status;
  Alcotest.check Alcotest.bool "health is present" true
    (Option.is_some state.health);
  let health = Option.get state.health in
  Alcotest.check Alcotest.string "health status" "healthy" health.status;
  Alcotest.check Alcotest.int "failing streak" 0 health.failing_streak;
  Alcotest.check Alcotest.int "log entries" 1 (List.length health.log);
  let entry = List.hd health.log in
  Alcotest.check Alcotest.string "log output" "OK\n" entry.output;
  Alcotest.check Alcotest.int "log exit code" 0 entry.exit_code

let test_inspect_state_without_health_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "Status": "running",
        "ExitCode": 0
      }|}
  in
  let state = Docker.inspect_state_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "status" "running" state.status;
  Alcotest.check Alcotest.bool "health is absent" false
    (Option.is_some state.health)

let test_inspect_state_unhealthy_with_streak_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "Status": "running",
        "ExitCode": 0,
        "Health": {
          "Status": "unhealthy",
          "FailingStreak": 3,
          "Log": [
            {"Output": "connection refused\n", "ExitCode": 1},
            {"Output": "connection refused\n", "ExitCode": 1},
            {"Output": "connection refused\n", "ExitCode": 1}
          ]
        }
      }|}
  in
  let state = Docker.inspect_state_of_yojson json |> unwrap in
  let health = Option.get state.health in
  Alcotest.check Alcotest.string "health status" "unhealthy" health.status;
  Alcotest.check Alcotest.int "failing streak" 3 health.failing_streak;
  Alcotest.check Alcotest.int "log entries" 3 (List.length health.log)

let test_health_state_defaults_json () =
  let json =
    Yojson.Safe.from_string {|{
        "Status": "starting"
      }|}
  in
  let health = Docker.health_state_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "status" "starting" health.status;
  Alcotest.check Alcotest.int "default failing streak" 0 health.failing_streak;
  Alcotest.check Alcotest.int "default log" 0 (List.length health.log)

(* An inspect payload shaped like the one the Engine actually returns: the
   restart policy Bondi has to read back sits inside a HostConfig object
   carrying dozens of sibling keys this client models none of. *)
let inspect_payload : host_config:string -> string =
 fun ~host_config ->
  Printf.sprintf
    {|{
        "Created": "2026-09-02T10:00:00Z",
        "RestartCount": 0,
        "State": {"Status": "running", "ExitCode": 0}%s
      }|}
    host_config

let applied_host_config : string =
  {|,
        "HostConfig": {
          "Annotations": {},
          "AutoRemove": false,
          "Binds": [],
          "CapAdd": [],
          "CgroupnsMode": "private",
          "ConsoleSize": [0, 0],
          "ContainerIDFile": "",
          "NetworkMode": "bridge",
          "PortBindings": {},
          "RestartPolicy": {"Name": "unless-stopped", "MaximumRetryCount": 0}
        }|}

let test_inspect_response_decodes_the_applied_restart_policy () =
  let json =
    Yojson.Safe.from_string (inspect_payload ~host_config:applied_host_config)
  in
  let response = Docker.inspect_response_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "state status" "running" response.state.status;
  match response.host_config with
  | None -> Alcotest.fail "inspect response carries no host config"
  | Some host_config -> (
      match host_config.restart_policy with
      | None -> Alcotest.fail "host config carries no restart policy"
      | Some policy ->
          Alcotest.check Alcotest.string "applied restart policy"
            "unless-stopped" policy.name;
          Alcotest.check
            (Alcotest.option Alcotest.int)
            "applied maximum retry count" (Some 0) policy.maximum_retry_count)

(* The Engine adds keys to its leaf objects the same way it adds them to
   HostConfig itself: a daemon newer than this client returns fields no record
   here models. A leaf that rejects them fails the whole inspect decode, which
   is every caller of inspect_container at once. *)
let host_config_with_unmodelled_leaf_keys : string =
  {|,
        "HostConfig": {
          "NetworkMode": "bridge",
          "PortBindings": {
            "8080/tcp": [
              {"HostIp": "127.0.0.1", "HostPort": "8080", "HostPortRange": ""}
            ]
          },
          "RestartPolicy": {
            "Name": "unless-stopped",
            "MaximumRetryCount": 0,
            "MaximumTimeout": 0
          }
        }|}

let test_inspect_response_tolerates_unmodelled_leaf_keys () =
  let json =
    Yojson.Safe.from_string
      (inspect_payload ~host_config:host_config_with_unmodelled_leaf_keys)
  in
  let response = Docker.inspect_response_of_yojson json |> unwrap in
  match response.host_config with
  | None -> Alcotest.fail "inspect response carries no host config"
  | Some host_config -> (
      (match host_config.restart_policy with
      | None -> Alcotest.fail "host config carries no restart policy"
      | Some policy ->
          Alcotest.check Alcotest.string "applied restart policy"
            "unless-stopped" policy.name);
      match host_config.port_bindings with
      | None -> Alcotest.fail "host config carries no port bindings"
      | Some bindings -> (
          match List.assoc_opt "8080/tcp" bindings with
          | Some [ binding ] ->
              Alcotest.check
                (Alcotest.option Alcotest.string)
                "host port" (Some "8080") binding.host_port
          | Some _
          | None ->
              Alcotest.fail "port binding for 8080/tcp missing"))

let test_inspect_response_without_host_config_decodes () =
  let json = Yojson.Safe.from_string (inspect_payload ~host_config:"") in
  let response = Docker.inspect_response_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "state status" "running" response.state.status;
  Alcotest.check Alcotest.bool "host config is absent" false
    (Option.is_some response.host_config)

(* One fixture for both arms of the Mounts encoding, differing only in
   [mounts]: the absence arm below is only evidence while the same record, given
   mounts, puts a Mounts key on the wire. *)
let workload_host_config ~(mounts : Docker.mount list option) :
    Docker.host_config =
  {
    binds = None;
    port_bindings = None;
    network_mode = None;
    restart_policy =
      Some { Docker.name = "unless-stopped"; maximum_retry_count = None };
    mounts;
  }

let test_host_config_encodes_bind_mounts () =
  let mounts : Docker.mount list =
    [
      {
        type_ = "bind";
        source = "/srv/comalito/invoices";
        target = "/app/invoices";
        read_only = false;
      };
      {
        type_ = "bind";
        source = "/etc/comalito";
        target = "/app/config";
        read_only = true;
      };
    ]
  in
  Alcotest.check Alcotest.string "host config body"
    ({|{"RestartPolicy":{"Name":"unless-stopped"},"Mounts":[|}
   ^ {|{"Type":"bind","Source":"/srv/comalito/invoices","Target":"/app/invoices","ReadOnly":false},|}
   ^ {|{"Type":"bind","Source":"/etc/comalito","Target":"/app/config","ReadOnly":true}]}|}
    )
    (Yojson.Safe.to_string
       (Docker.host_config_to_yojson
          (workload_host_config ~mounts:(Some mounts))))

let test_host_config_without_mounts_has_no_mounts_key () =
  Alcotest.check Alcotest.string "host config body"
    {|{"RestartPolicy":{"Name":"unless-stopped"}}|}
    (Yojson.Safe.to_string
       (Docker.host_config_to_yojson (workload_host_config ~mounts:None)))

(* HostConfig.Mounts as the Engine reports it back, captured from Engine 29.8.1
   (API 1.56) on 2026-09-27 by inspecting a container created with one
   read-write and one read-only bind mount [observed]. The read-write entry
   carries no ReadOnly key at all: the Engine omits a false one. A decode that
   required the key would fail every inspect of a container Bondi mounted
   read-write, and the blue-green health wait inspects exactly that container.
   The BindOptions key is not from that capture: it stands for any key of a
   mount entry this client does not model, which must not fail the decode. *)
let host_config_with_reported_mounts : string =
  {|,
        "HostConfig": {
          "NetworkMode": "bridge",
          "RestartPolicy": {"Name": "unless-stopped", "MaximumRetryCount": 0},
          "Mounts": [
            {"Type": "bind", "Source": "/srv/comalito/invoices",
             "Target": "/app/invoices"},
            {"Type": "bind", "Source": "/etc/comalito", "Target": "/app/config",
             "ReadOnly": true, "BindOptions": {"Propagation": "rprivate"}}
          ]
        }|}

let mount_testable = Server_test_helpers.mount_testable

let test_inspect_response_decodes_reported_mounts () =
  let json =
    Yojson.Safe.from_string
      (inspect_payload ~host_config:host_config_with_reported_mounts)
  in
  let response = Docker.inspect_response_of_yojson json |> unwrap in
  match response.host_config with
  | None -> Alcotest.fail "inspect response carries no host config"
  | Some host_config ->
      Alcotest.check
        (Alcotest.option (Alcotest.list mount_testable))
        "reported mounts"
        (Some
           [
             {
               type_ = "bind";
               source = "/srv/comalito/invoices";
               target = "/app/invoices";
               read_only = false;
             };
             {
               type_ = "bind";
               source = "/etc/comalito";
               target = "/app/config";
               read_only = true;
             };
           ])
        host_config.mounts

let test_update_container_serialises_the_restart_policy () =
  let request : Docker.update_container_request =
    {
      restart_policy =
        { Docker.name = "unless-stopped"; maximum_retry_count = None };
    }
  in
  Alcotest.check Alcotest.string "update request body"
    {|{"RestartPolicy":{"Name":"unless-stopped"}}|}
    (Yojson.Safe.to_string (Docker.update_container_request_to_yojson request))

(* The bound is the only place a stalled Engine socket becomes a value. The
   mock clock advances on its own once nothing is runnable, so the deadline
   fires without the test waiting ten real seconds. *)
let test_request_bound_reports_the_deadline () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let result =
    Docker.with_request_bound ~clock ~what:"inspect of container abc123"
      (fun () ->
        Eio.Time.sleep clock 3600.0;
        Ok ())
  in
  match result with
  | Ok () -> Alcotest.fail "expected the request bound to report a timeout"
  | Error msg ->
      Alcotest.check Alcotest.string "timeout message"
        "docker inspect of container abc123 did not answer within 10 seconds"
        msg

(* The affirmative arm: a request that answers inside the bound is returned
   untouched, so the arm above is caused by the deadline and not by the bound
   rejecting every request. *)
let test_request_bound_passes_a_prompt_answer_through () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let result =
    Docker.with_request_bound ~clock ~what:"inspect of container abc123"
      (fun () ->
        Eio.Time.sleep clock 1.0;
        Ok "answered")
  in
  Alcotest.check
    (Alcotest.result Alcotest.string Alcotest.string)
    "answer passed through" (Ok "answered") result

(* A real payload, captured from Docker Engine 29.8.0 on 2026-09-15 with
   [curl --unix-socket /var/run/docker.sock http://localhost/version], trimmed
   to the fields Bondi reads. The decode is [strict = false] precisely so the
   rest of that response -- Components, Platform, build metadata -- is ignored
   rather than being a decode failure on every engine that adds a field. *)
let test_version_response_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "Platform": { "Name": "Docker Engine - Community" },
        "Version": "29.8.0",
        "ApiVersion": "1.56",
        "MinAPIVersion": "1.40",
        "Os": "linux",
        "Arch": "amd64"
      }|}
  in
  let response = Docker.version_response_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "the ceiling" "1.56" response.api_version;
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "the floor" (Some "1.40") response.min_api_version

(* MinAPIVersion is absent before Engine 1.13, and an absent floor must decode
   rather than fail: a daemon that does not report one still answers requests. *)
let test_version_response_without_a_minimum_json () =
  let json = Yojson.Safe.from_string {|{ "ApiVersion": "1.24" }|} in
  let response = Docker.version_response_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "the ceiling" "1.24" response.api_version;
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "no floor reported" None response.min_api_version

(* The tagged entry follows the ImageSummary example of the Docker Engine API
   v1.41 reference, https://docs.docker.com/engine/api/v1.41/#tag/Image/operation/ImageList
   (response schema ImageSummary). The untagged entry is the same shape with
   the RepoTags a daemon reports for an image that has lost its last tag: an
   empty list on current engines. Only Id and RepoTags are read; every other
   key must be tolerated, as an engine adds keys between versions. *)
let test_list_images_decodes_recorded_body () =
  let json =
    Yojson.Safe.from_string
      {|[
        {
          "Id": "sha256:ec3f0931a6e6b6855d76b2d7b0be30e81860baccd891b2e243280bf1cd8ad710",
          "ParentId": "",
          "RepoTags": [
            "example:1.0",
            "example:latest",
            "example:stable",
            "internal.registry.example.com:5000/example:1.0"
          ],
          "RepoDigests": [
            "example@sha256:afcc7f1ac1b49db317a7196c902e61c6c3c4607d63599ee1a82d702d249a0ccb",
            "internal.registry.example.com:5000/example@sha256:b69959407d21e8a062e0416bf13405bb2b71ed7a84dde4158ebafacfa06f5578"
          ],
          "Created": 1644009612,
          "Size": 172064416,
          "SharedSize": 1239828,
          "VirtualSize": 172064416,
          "Labels": {
            "com.example.some-label": "some-value",
            "com.example.some-other-label": "some-other-value"
          },
          "Containers": 2
        },
        {
          "Id": "sha256:a44854fbf6b6c1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920",
          "ParentId": "",
          "RepoTags": [],
          "RepoDigests": [],
          "Created": 1644009600,
          "Size": 172064416,
          "SharedSize": -1,
          "VirtualSize": 172064416,
          "Labels": null,
          "Containers": -1
        }
      ]|}
  in
  let images = Docker.image_summaries_of_json json |> unwrap in
  Alcotest.check
    Alcotest.(list (pair string (list string)))
    "ids and tags, in listing order"
    [
      ( "sha256:ec3f0931a6e6b6855d76b2d7b0be30e81860baccd891b2e243280bf1cd8ad710",
        [
          "example:1.0";
          "example:latest";
          "example:stable";
          "internal.registry.example.com:5000/example:1.0";
        ] );
      ( "sha256:a44854fbf6b6c1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920",
        [] );
    ]
    (List.map
       (fun (image : Docker.Image_summary.t) -> (image.id, image.repo_tags))
       images)

let expect_error_containing what needle result =
  match result with
  | Ok _ -> Alcotest.fail (what ^ ": expected an Error")
  | Error msg ->
      Alcotest.(check bool)
        (what ^ ": message " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle msg)

let test_list_images_rejects_a_malformed_entry_bounded () =
  let long = String.make 5000 'x' in
  let json = `List [ `Assoc [ ("Id", `Int 7); ("Pad", `String long) ] ] in
  let result = Docker.image_summaries_of_json json in
  expect_error_containing "entry shown" "\"Id\":7" result;
  expect_error_containing "entry bounded" "truncated" result;
  match result with
  | Error msg ->
      Alcotest.(check bool) "message is short" true (String.length msg < 1500)
  | Ok _ -> ()

let test_list_images_rejects_a_non_array_bounded () =
  let long = String.make 5000 'y' in
  let json = `Assoc [ ("message", `String long) ] in
  let result = Docker.image_summaries_of_json json in
  expect_error_containing "body shown" "\"message\"" result;
  expect_error_containing "body bounded" "truncated" result

let test_list_images_rejects_a_missing_repo_tags () =
  let json = `List [ `Assoc [ ("Id", `String "sha256:abc") ] ] in
  match Docker.image_summaries_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a missing RepoTags must not read as untagged"

let test_remove_image_query_has_no_force () =
  Alcotest.(check bool)
    "no force" false
    (List.mem_assoc "force" Docker.remove_image_query);
  Alcotest.(check bool)
    "noprune sent" true
    (List.mem_assoc "noprune" Docker.remove_image_query)

(* Some daemon versions report an untagged image's RepoTags as null rather than
   an empty list; both mean the image carries no tag. *)
let test_list_images_decodes_untagged_image () =
  let json =
    Yojson.Safe.from_string
      {|[
        {
          "Id": "sha256:a44854fbf6b6c1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920",
          "ParentId": "",
          "RepoTags": null,
          "RepoDigests": null,
          "Created": 1644009600,
          "Size": 172064416,
          "Containers": -1
        }
      ]|}
  in
  let images = Docker.image_summaries_of_json json |> unwrap in
  Alcotest.check
    Alcotest.(list (pair string (list string)))
    "the id, and no tags"
    [
      ( "sha256:a44854fbf6b6c1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920",
        [] );
    ]
    (List.map
       (fun (image : Docker.Image_summary.t) -> (image.id, image.repo_tags))
       images)

(* The reference filter is what narrows the listing to one repository's images.
   Its wire form is the Engine API's [filters] parameter: a JSON-encoded
   map[string][]string, here {"reference":[...]}, per the same v1.41 reference.
   With no reference there is no filter and the listing covers every image. *)
let test_list_images_filters_by_reference () =
  Alcotest.check
    Alcotest.(list (pair string (list string)))
    "a reference becomes the filters parameter"
    [ ("filters", [ {|{"reference":["ghcr.io/acme/app"]}|} ]) ]
    (Docker.list_images_query ~reference:(Some "ghcr.io/acme/app"));
  Alcotest.check
    Alcotest.(list (pair string (list string)))
    "no reference, no filter" []
    (Docker.list_images_query ~reference:None)

let () =
  Alcotest.run "Docker.Client"
    [
      ( "image list",
        [
          Alcotest.test_case "decodes a recorded body" `Quick
            test_list_images_decodes_recorded_body;
          Alcotest.test_case "decodes an untagged image" `Quick
            test_list_images_decodes_untagged_image;
          Alcotest.test_case "filters by reference" `Quick
            test_list_images_filters_by_reference;
          Alcotest.test_case "bounds a malformed entry in the error" `Quick
            test_list_images_rejects_a_malformed_entry_bounded;
          Alcotest.test_case "bounds a non-array body in the error" `Quick
            test_list_images_rejects_a_non_array_bounded;
          Alcotest.test_case "refuses a missing RepoTags" `Quick
            test_list_images_rejects_a_missing_repo_tags;
          Alcotest.test_case "removal carries no force" `Quick
            test_remove_image_query_has_no_force;
        ] );
      ( "image inspect",
        [
          Alcotest.test_case "with healthcheck" `Quick
            test_image_inspect_response_with_healthcheck_json;
          Alcotest.test_case "without healthcheck" `Quick
            test_image_inspect_response_without_healthcheck_json;
        ] );
      ( "restart policy",
        [
          Alcotest.test_case "inspect decodes the applied policy" `Quick
            test_inspect_response_decodes_the_applied_restart_policy;
          Alcotest.test_case "inspect tolerates unmodelled leaf keys" `Quick
            test_inspect_response_tolerates_unmodelled_leaf_keys;
          Alcotest.test_case "inspect without host config" `Quick
            test_inspect_response_without_host_config_decodes;
          Alcotest.test_case "update serialises the policy" `Quick
            test_update_container_serialises_the_restart_policy;
        ] );
      ( "mounts",
        [
          Alcotest.test_case "host config encodes bind mounts" `Quick
            test_host_config_encodes_bind_mounts;
          Alcotest.test_case "host config without mounts has no Mounts key"
            `Quick test_host_config_without_mounts_has_no_mounts_key;
          Alcotest.test_case "inspect decodes mounts as the Engine reports them"
            `Quick test_inspect_response_decodes_reported_mounts;
        ] );
      ( "request bound",
        [
          Alcotest.test_case "reports the deadline" `Quick
            test_request_bound_reports_the_deadline;
          Alcotest.test_case "passes a prompt answer through" `Quick
            test_request_bound_passes_a_prompt_answer_through;
        ] );
      ( "inspect state health",
        [
          Alcotest.test_case "with health" `Quick
            test_inspect_state_with_health_json;
          Alcotest.test_case "without health" `Quick
            test_inspect_state_without_health_json;
          Alcotest.test_case "unhealthy with streak" `Quick
            test_inspect_state_unhealthy_with_streak_json;
          Alcotest.test_case "health state defaults" `Quick
            test_health_state_defaults_json;
        ] );
      ( "daemon version",
        [
          Alcotest.test_case "a real payload" `Quick test_version_response_json;
          Alcotest.test_case "no minimum reported" `Quick
            test_version_response_without_a_minimum_json;
        ] );
    ]

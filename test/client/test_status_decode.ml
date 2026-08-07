open Alcotest
module Status = Bondi_client.Orchestrator_status
module Report = Bondi_client.Status_report

(* --- The captured response ---

   fixtures/orchestrator_status_response.json was not written here. It is the
   body of GET /api/v1/status, recorded verbatim off a running orchestrator:

     image     mlopez1506/bondi-server:latest
               sha256:de53659011631034bef1e6c6bbc417853f4df7815e6f687aa175a425cc7cdbd6
     built     2026-08-01T03:24:13Z
     captured  2026-08-04T04:42Z, against a host carrying a service, two
               scheduled jobs of which one had run, the orchestrator itself,
               Traefik, Alloy and one managed container
     rechecked 2026-08-04, by building the server image from 321580f, capturing
               a second response the same way, and diffing the two by key and
               type: identical. So this body is what that commit's server
               produces and not only what an older build did.

   Capturing it rather than authoring it is the point: a body written to match
   what this client expects agrees with the client by construction and keeps
   agreeing after the server stops producing it. When the response's shape
   changes, this file is recaptured the same way — which is an edit somebody
   makes and a reviewer sees, rather than a drift nothing reports.

   What it does not cover is the socket: that Cohttp reaches a server and returns
   bytes. That is the library's behaviour and every real run exercises it. *)

let captured_response =
  let path = "fixtures/orchestrator_status_response.json" in
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let decoded () =
  match
    Status.comprehensive_status_of_yojson
      (Yojson.Safe.from_string captured_response)
  with
  | Ok status -> status
  | Error message -> failf "the captured response did not decode: %s" message

let component_named name components =
  match
    List.find_opt
      (fun (component : Report.component) -> String.equal component.name name)
      components
  with
  | Some component -> component
  | None ->
      failf "expected a component named %s, got: %s" name
        (String.concat ", "
           (List.map
              (fun (component : Report.component) -> component.name)
              components))

let observation_state name components =
  (component_named name components).observation.state

(* --- Tests --- *)

(* 1. The decoder reads a real body. A response the client cannot decode reaches
      the report as an unreachable orchestrator, so a decode that silently
      stopped working would look exactly like a server that is down. *)
let test_decode_captured_response () =
  let status = decoded () in
  let service =
    match status.service with
    | Some service -> service
    | None -> failf "the captured response names a service and it was dropped"
  in
  check string "the service keeps the name the host gave it" "my-service"
    service.name;
  check string "the image is separated from its tag" "docker.io/library/alpine"
    service.image_name;
  check string "and the tag with it" "latest" service.tag;
  check (option int) "a restart count the response carries survives" (Some 0)
    service.restart_count;
  check int "both scheduled jobs are read" 2 (List.length status.cron_jobs);
  check (list string) "including the errors list, empty here" [] status.errors

(* 2. Every section of the response becomes a component keyed by the name the
      host uses, so the merge can put both sources on one row. A section the
      flattening forgets is a row that silently loses its orchestrator side. *)
let test_decode_maps_every_section_onto_components () =
  let components = Status.components_of (decoded ()) in
  check int "every section contributes" 7 (List.length components);
  check string "the service" "running"
    (observation_state "my-service" components);
  check string "the orchestrator's own row" "running"
    (observation_state "bondi-orchestrator" components);
  check string "Traefik" "running"
    (observation_state "bondi-traefik" components);
  check string "Alloy" "running" (observation_state "bondi-alloy" components);
  check string "a managed container" "running"
    (observation_state "ibgateway" components);
  (* The fact SSH cannot reconstruct: the job's container is removed after it
     runs, so a run that finished is only ever the orchestrator's to report. *)
  check string "a job that has run" "completed"
    (observation_state "daily-close" components);
  check string "and one that has not" "scheduled"
    (observation_state "rebalance" components);
  (* The orchestrator reports no health of its own. A component arriving with one
     would mean the report had two answers to a question only the host can
     answer. *)
  List.iter
    (fun (component : Report.component) ->
      match component.observation.health with
      | None -> ()
      | Some _ ->
          failf "%s arrived carrying a health the orchestrator cannot know"
            component.name)
    components

(* 3. The affirmative arm's opposite: a body this client cannot read is a
      rejection, not an empty status. Decoding it as one would report every
      declared component as absent on a server that is answering. *)
let test_decode_rejects_a_response_it_cannot_read () =
  let missing_a_required_field = {|{"service":null,"infrastructure":{}}|} in
  match
    Status.comprehensive_status_of_yojson
      (Yojson.Safe.from_string missing_a_required_field)
  with
  | Error _ -> ()
  | Ok _ ->
      fail
        "a response missing the fields this client reads must not decode as an \
         empty status"

(* 4. What the operator is told when a body does not read. Two things have to be
      true of it, and neither was.

      It must not say the orchestrator was unreachable. The server answered —
      the socket worked, the port was right, something replied — and "not
      reachable" sends the reader to the network when the fault is at the other
      end of a connection that plainly worked. The usual cause is a skew between
      this client and that orchestrator's version.

      And it must carry what arrived. That body is the only evidence of what
      answered, and discarding it leaves a report that says something went wrong
      without saying what, at exactly the moment the answer would have named the
      cause.

      Both arms are here because the two ways a body fails to read — not JSON at
      all, and JSON of the wrong shape — arrive on different paths, one of them
      as a raised exception. *)
let unavailability_of ~what body =
  match Status.reading_of_body ~ip_address:"10.0.0.1" body with
  | Error unavailability -> unavailability
  | Ok _ -> failf "%s must not read as a status" what

let check_names_the_answer ~what ~fragment body =
  match unavailability_of ~what body with
  | Report.Not_understood message ->
      check bool
        (what ^ " carries what the server actually said")
        true
        (Bondi_common.String_utils.contains ~needle:fragment message);
      check bool
        (what ^ " does not claim the server was unreachable")
        false
        (Bondi_common.String_utils.contains ~needle:"not reachable" message)
  | Report.Not_consulted message ->
      failf "%s answered, so it was consulted: %s" what message

(* Each fragment sits late in its body, past anything a parser quotes back in
   its own complaint. A fragment the decoder's error message happens to repeat
   would be satisfied by an implementation that discarded the body entirely,
   which is the implementation these two arms exist to reject. *)
let test_decode_an_unreadable_body_names_what_answered () =
  check_names_the_answer ~what:"a body that is not JSON at all"
    ~fragment:"nginx/1.24.0"
    "<html><head><title>502 Bad Gateway</title></head><body><center>502 Bad \
     Gateway</center><hr><center>nginx/1.24.0</center></body></html>";
  check_names_the_answer ~what:"a body that is JSON of the wrong shape"
    ~fragment:"a-server-three-versions-old"
    {|{"service":null,"infrastructure":{},"produced_by":"a-server-three-versions-old"}|}

(* Its affirmative arm on the captured body: the same call reads a real response
   into a reading. Without it, a [reading_of_body] that rejected everything
   would satisfy the case above. *)
let test_decode_reading_of_body_reads_the_captured_response () =
  match Status.reading_of_body ~ip_address:"10.0.0.1" captured_response with
  | Ok reading ->
      check int "every section reaches the reading" 7
        (List.length reading.components);
      check (list string) "and the response's own warnings come with it" []
        reading.warnings
  | Error (Report.Not_consulted message)
  | Error (Report.Not_understood message) ->
      failf "the captured response did not read: %s" message

let () =
  run "status decode"
    [
      ( "captured",
        [
          test_case "a real response decodes" `Quick
            test_decode_captured_response;
          test_case "every section becomes a component" `Quick
            test_decode_maps_every_section_onto_components;
          test_case "a response that cannot be read is rejected" `Quick
            test_decode_rejects_a_response_it_cannot_read;
        ] );
      ( "unreadable answers",
        [
          test_case "name what answered, and are not unreachability" `Quick
            test_decode_an_unreadable_body_names_what_answered;
          test_case "the captured response still reads" `Quick
            test_decode_reading_of_body_reads_the_captured_response;
        ] );
    ]

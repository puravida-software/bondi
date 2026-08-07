type observation = {
  image : string;
  tag : string;
  state : string;
  health : Host_inventory.health option;
  wait : Container_health.verdict option;
  restart_count : int option;
  created_at : string option;
}

type unavailability = Not_consulted of string | Not_understood of string

type source_view =
  | Reported of observation
  | Absent
  | Unavailable of unavailability

type declaration = Declared | Undeclared
type kind = Service | Cron_job | Infrastructure

type row = {
  name : string;
  kind : kind;
  declaration : declaration;
  docker : source_view;
  orchestrator : source_view;
}

type component = { name : string; observation : observation }

(* The names the setup phase gives the components it installs. The orchestrator
   is here unconditionally: every configuration has one, and a row for it that
   depended on anything would be missing on the run that needs it most. *)
let orchestrator_container_name = "bondi-orchestrator"
let traefik_container_name = "bondi-traefik"
let alloy_container_name = "bondi-alloy"

let service_components (config : Config_file.t) =
  match config.user_service with
  | None -> []
  | Some service -> [ (service.name, Service) ]

let cron_job_components (config : Config_file.t) =
  match config.cron_jobs with
  | None -> []
  | Some jobs ->
      List.map (fun (job : Config_file.cron_job) -> (job.name, Cron_job)) jobs

let traefik_components (config : Config_file.t) =
  match config.traefik with
  | None -> []
  | Some _ -> [ (traefik_container_name, Infrastructure) ]

let alloy_components (config : Config_file.t) =
  match config.alloy with
  | None -> []
  | Some _ -> [ (alloy_container_name, Infrastructure) ]

(* Declared containers are named as the setup phase names them on the box, so
   the two sources and the configuration are all keyed the same way. *)
let managed_components (config : Config_file.t) =
  match config.managed_containers with
  | None -> []
  | Some containers ->
      List.map
        (fun (container : Config_file.managed_container) ->
          ( Bondi_common.Managed_container.container_name_of container.name,
            Infrastructure ))
        containers

let declared_components config =
  service_components config
  @ cron_job_components config
  @ [ (orchestrator_container_name, Infrastructure) ]
  @ traefik_components config
  @ alloy_components config
  @ managed_components config

(* A wait is only ever the host's, and only ever about a container the host
   reported, so it is carried inside that source's own account rather than
   beside it: a verdict on a row no source has is a failure with nowhere to be
   read, and this is the shape in which there is no such thing. *)
let observation_of_container ~waits (container : Host_inventory.container) =
  {
    image = container.image;
    tag = container.tag;
    state = container.state;
    health = Some container.health;
    wait = List.assoc_opt container.name waits;
    restart_count = container.restart_count;
    created_at = container.created_at;
  }

let docker_view ~docker ~waits name =
  match docker with
  | Host_inventory.Unreadable_listing message ->
      Unavailable (Not_consulted message)
  | Host_inventory.Observed containers -> (
      match
        List.find_opt
          (fun (container : Host_inventory.container) ->
            String.equal container.name name)
          containers
      with
      | Some container -> Reported (observation_of_container ~waits container)
      | None -> Absent)

let orchestrator_view ~orchestrator name =
  match orchestrator with
  | Error unavailability -> Unavailable unavailability
  | Ok components -> (
      match
        List.find_opt
          (fun (component : component) -> String.equal component.name name)
          components
      with
      | Some component -> Reported component.observation
      | None -> Absent)

let observed_names docker =
  match docker with
  | Host_inventory.Unreadable_listing _ -> []
  | Host_inventory.Observed containers ->
      List.map
        (fun (container : Host_inventory.container) -> container.name)
        containers

let reported_names orchestrator =
  match orchestrator with
  | Error _ -> []
  | Ok components ->
      List.map (fun (component : component) -> component.name) components

let without_duplicates names =
  List.fold_left
    (fun kept name ->
      match List.exists (String.equal name) kept with
      | true -> kept
      | false -> name :: kept)
    [] names
  |> List.rev

let row_of ~docker ~orchestrator ~waits ~kind ~declaration name =
  {
    name;
    kind;
    declaration;
    docker = docker_view ~docker ~waits name;
    orchestrator = orchestrator_view ~orchestrator name;
  }

let rows ~config ~docker ~orchestrator ~waits =
  let declared = declared_components config in
  let is_declared name =
    List.exists
      (fun (declared_name, _) -> String.equal declared_name name)
      declared
  in
  (* Everything either source found and nothing declares. A container running
     that no configuration asks for is what the next run removes, so it belongs
     in the report whichever source saw it. *)
  let undeclared =
    observed_names docker @ reported_names orchestrator
    |> List.filter (fun name -> not (is_declared name))
    |> without_duplicates
  in
  List.map
    (fun (name, kind) ->
      row_of ~docker ~orchestrator ~waits ~kind ~declaration:Declared name)
    declared
  @ List.map
      (fun name ->
        row_of ~docker ~orchestrator ~waits ~kind:Infrastructure
          ~declaration:Undeclared name)
      undeclared

(* The reference each source was describing, put back together. The two split it
   with different parsers — the host's knows a digest names no tag, the
   orchestrator's splits on a colon — so comparing the halves reports two
   containers where there is one, on every run and forever, for any image pinned
   by digest. Rejoining and splitting once with a single parser compares what
   the sources actually said rather than how each of them cut it up. *)
let image_reference observation =
  match observation.tag with
  | "" -> observation.image
  | tag -> observation.image ^ ":" ^ tag

let normalised_image observation =
  Host_inventory.split_image (image_reference observation)

(* Only what the two sources claim is running can contradict: the image, its
   tag and the state. A restart count read a second later legitimately differs
   and would flag a row on nothing but the gap between the two reads. *)
let same_component host orchestrator =
  let host_image, host_tag = normalised_image host in
  let orchestrator_image, orchestrator_tag = normalised_image orchestrator in
  String.equal host_image orchestrator_image
  && String.equal host_tag orchestrator_tag
  && String.equal host.state orchestrator.state

let disagrees row =
  match (row.docker, row.orchestrator) with
  | Reported host, Reported orchestrator ->
      not (same_component host orchestrator)
  | Reported _, (Absent | Unavailable _)
  | (Absent | Unavailable _), (Reported _ | Absent | Unavailable _) ->
      false

(* Deliberately not "did it pass" negated. A container that defines no
   healthcheck has passed nothing, and reading that as a failure fails every run
   on every container without a check — which is most of them, and every one
   this project ships today. The question here is a different one: may the run
   still claim success? Only a check that passed and a container with none to
   pass allow it. *)
let fails_the_run = function
  | Container_health.Healthy
  | Container_health.No_healthcheck ->
      false
  | Container_health.Unhealthy _
  | Container_health.Timed_out _
  | Container_health.Gone
  | Container_health.Unreadable _ ->
      true

(* Only what the configuration asks for. A run converges what is declared, and
   its exit code answers whether it managed to; a container nothing declares is
   on the box for reasons this run neither chose nor touched, so letting one
   decide the answer settles the question with something outside it. The row
   keeps its verdict either way — showing what is there and deciding what the
   run achieved are different jobs. *)
let decides_the_exit_code row =
  match row.declaration with
  | Declared -> true
  | Undeclared -> false

let exit_failure rows =
  List.exists
    (fun row ->
      match (decides_the_exit_code row, row.docker) with
      | false, (Reported _ | Absent | Unavailable _) -> false
      | true, Reported observation -> (
          match observation.wait with
          | Some verdict -> fails_the_run verdict
          | None -> false)
      | true, (Absent | Unavailable _) -> false)
    rows

type server_report = {
  address : string;
  rows : row list;
  crontab : Crontab_listing.t;
  warnings : string list;
}

(* How a source is named in the table, and how a source that could not answer
   says so. The two words differ because the two failures do: the host was not
   read, and the orchestrator was not reachable. *)
type side = { label : string; silence : string }

let host_side = { label = "docker"; silence = "not read" }
let orchestrator_side = { label = "orch"; silence = "not reachable" }

(* One source's account of a component, on one line. Sources agreeing collapse
   onto a single line naming both, because two identical lines are noise rather
   than provenance; nothing else ever merges. *)
let agreed_label = "both"

(* Seven cells of the same type, so every one is named at the call site: a
   transposition the compiler cannot see is a garbled table, and this is the one
   function every line in the report is built by. *)
let columns ~name ~source ~image ~tag ~state ~restarts ~health =
  Printf.sprintf "  %-22s %-7s %-32s %-12s %-13s %-9s %s" name source image tag
    state restarts health

let table_header =
  columns ~name:"NAME" ~source:"SOURCE" ~image:"IMAGE" ~tag:"TAG"
    ~state:"STATUS" ~restarts:"RESTARTS" ~health:"HEALTH"

let restarts_cell = function
  | Some count -> string_of_int count
  | None -> "N/A"

(* A container with no healthcheck and one whose health was never read have both
   passed nothing, and neither cell may read as a result. Only a check that
   passed says healthy. *)
let health_cell = function
  | None -> "-"
  | Some Host_inventory.Healthy -> "healthy"
  | Some (Host_inventory.Unhealthy _) -> "unhealthy"
  | Some Host_inventory.Starting -> "starting"
  | Some Host_inventory.No_healthcheck -> "no healthcheck defined"
  | Some Host_inventory.Not_recorded -> "no health recorded"
  | Some (Host_inventory.Unreadable message) ->
      "could not be read: " ^ Bondi_common.String_utils.single_line message

(* A wait is a second reading of the same field, taken later and on purpose, so
   where one was taken it is the health cell rather than a column beside it: two
   health words on one line invite a reader to choose between them, and only one
   of the two is about the box as the run left it. The bound is the host's own
   number, not the one this client meant to ask for. *)
let wait_cell = function
  | Container_health.Healthy -> "healthy"
  | Container_health.Unhealthy streak ->
      "unhealthy: " ^ Bondi_common.String_utils.single_line streak
  | Container_health.No_healthcheck -> "no healthcheck defined"
  | Container_health.Timed_out { seconds } ->
      Printf.sprintf "did not pass its healthcheck within %ds" seconds
  | Container_health.Gone -> "stopped before it passed its healthcheck"
  | Container_health.Unreadable message ->
      "health could not be read: "
      ^ Bondi_common.String_utils.single_line message

let health_of observation =
  match observation.wait with
  | Some verdict -> wait_cell verdict
  | None -> health_cell observation.health

let observation_line ~name ~source observation =
  columns ~name ~source ~image:observation.image ~tag:observation.tag
    ~state:observation.state
    ~restarts:(restarts_cell observation.restart_count)
    ~health:(health_of observation)

let absent_line ~name ~source =
  columns ~name ~source ~image:"-" ~tag:"-" ~state:"not found" ~restarts:"-"
    ~health:"-"

(* Which failure this was, in the source's own words. A source that could not be
   consulted and a source that answered with something unreadable send an
   operator to two different places — the network, and a skew between this
   client and what answered it — so the two must not be spelled the same way.
   Only the first is the side's own word for silence; the second happened after
   the source spoke, so no wording about reaching it can be right. *)
let unavailability_words ~side = function
  | Not_consulted message -> (side.silence, message)
  | Not_understood message ->
      ("answered with something that could not be read", message)

(* A transport's own account of why it could not answer is free text and reaches
   here across as many lines as it likes; a cell that keeps them stops being a
   cell and its tail reads as a row of its own. *)
let silent_line ~name ~side unavailability =
  let silence, message = unavailability_words ~side unavailability in
  Printf.sprintf "  %-22s %-7s %s: %s" name side.label silence
    (Bondi_common.String_utils.single_line message)

(* The name is on the row's first line only; the second carries the other source
   under a blank name column, so a reader sees one component rather than two. *)
let continued = ""

let source_lines row =
  match (row.docker, row.orchestrator) with
  | Reported host, Reported orchestrator when same_component host orchestrator
    ->
      [ observation_line ~name:row.name ~source:agreed_label host ]
  | Reported host, Reported orchestrator ->
      [
        observation_line ~name:row.name ~source:host_side.label host;
        observation_line ~name:continued ~source:orchestrator_side.label
          orchestrator;
      ]
  | Reported host, Absent ->
      [ observation_line ~name:row.name ~source:host_side.label host ]
  | Absent, Reported orchestrator ->
      [
        observation_line ~name:row.name ~source:orchestrator_side.label
          orchestrator;
      ]
  | Reported host, Unavailable unavailability ->
      [
        observation_line ~name:row.name ~source:host_side.label host;
        silent_line ~name:continued ~side:orchestrator_side unavailability;
      ]
  | Unavailable unavailability, Reported orchestrator ->
      [
        silent_line ~name:row.name ~side:host_side unavailability;
        observation_line ~name:continued ~source:orchestrator_side.label
          orchestrator;
      ]
  | Absent, Absent -> [ absent_line ~name:row.name ~source:agreed_label ]
  | Absent, Unavailable unavailability ->
      [
        absent_line ~name:row.name ~source:host_side.label;
        silent_line ~name:continued ~side:orchestrator_side unavailability;
      ]
  | Unavailable unavailability, Absent ->
      [
        silent_line ~name:row.name ~side:host_side unavailability;
        absent_line ~name:continued ~source:orchestrator_side.label;
      ]
  | Unavailable host, Unavailable orchestrator ->
      [
        silent_line ~name:row.name ~side:host_side host;
        silent_line ~name:continued ~side:orchestrator_side orchestrator;
      ]

(* What the host could not confirm is not ground truth, and a reader who cannot
   see that will read it as though it were. *)
let unverified row =
  match (row.docker, row.orchestrator) with
  | Unavailable _, Reported _ -> true
  | (Reported _ | Absent | Unavailable _), (Reported _ | Absent | Unavailable _)
    ->
      false

let flags row =
  let flag carried word =
    match carried with
    | true -> [ word ]
    | false -> []
  in
  flag (disagrees row) "[disagreement]"
  @ flag (unverified row) "[unverified]"
  @ flag
      (match row.declaration with
      | Undeclared -> true
      | Declared -> false)
      "[undeclared]"

let row_lines row =
  match (flags row, source_lines row) with
  | [], lines -> lines
  | _ :: _, [] -> []
  | (_ :: _ as flags), first :: rest ->
      (first ^ "  " ^ String.concat " " flags) :: rest

let of_kind wanted rows =
  List.filter
    (fun row ->
      match (row.kind, wanted) with
      | Service, Service
      | Cron_job, Cron_job
      | Infrastructure, Infrastructure ->
          true
      | ( (Service | Cron_job | Infrastructure),
          (Service | Cron_job | Infrastructure) ) ->
          false)
    rows

let section title rows =
  match rows with
  | [] -> []
  | _ :: _ ->
      ([ title; table_header ] @ List.concat_map row_lines rows) @ [ "" ]

let entry_cell = function
  | Crontab_listing.Named job -> job
  | Crontab_listing.Unnamed { position } ->
      Printf.sprintf "entry %d could not be read" position

(* Counts, job names and positions. Never a line and never part of one: the
   spool file holds every job's API secret in plaintext. *)
let crontab_cell = function
  | Crontab_listing.Section { entries = [] } -> "0 jobs"
  | Crontab_listing.Section { entries } ->
      Printf.sprintf "%d jobs (%s)" (List.length entries)
        (String.concat ", " (List.map entry_cell entries))
  | Crontab_listing.No_section -> "no Bondi section on the host"
  | Crontab_listing.Malformed Crontab_listing.End_without_begin ->
      "markers malformed: a section closes that was never opened"
  | Crontab_listing.Malformed Crontab_listing.Begin_without_end ->
      "markers malformed: a section opens and the file ends inside it"
  | Crontab_listing.Malformed Crontab_listing.Nested_begin ->
      "markers malformed: a section opens inside one already open"
  | Crontab_listing.Unreadable message ->
      "not read: " ^ Bondi_common.String_utils.single_line message

let crontab_section listing =
  [
    "Crontab";
    Printf.sprintf "  %-22s %-7s %s" "bondi section" host_side.label
      (crontab_cell listing);
    "";
  ]

let warnings_section warnings =
  match warnings with
  | [] -> []
  | _ :: _ ->
      ("Warnings" :: List.map (fun warning -> "  " ^ warning) warnings) @ [ "" ]

let server_lines report =
  [ Printf.sprintf "Server: %s" report.address; "" ]
  @ section "Service" (of_kind Service report.rows)
  @ section "Cron Jobs" (of_kind Cron_job report.rows)
  @ section "Infrastructure" (of_kind Infrastructure report.rows)
  @ crontab_section report.crontab
  @ warnings_section report.warnings

let render_table reports =
  String.concat "\n" (List.concat_map server_lines reports)

let optional_string = function
  | Some value -> `String value
  | None -> `Null

let optional_int = function
  | Some value -> `Int value
  | None -> `Null

let observation_json observation =
  [
    ("image", `String observation.image);
    ("tag", `String observation.tag);
    ("state", `String observation.state);
    ("health", `String (health_of observation));
    ("restart_count", optional_int observation.restart_count);
    ("created_at", optional_string observation.created_at);
  ]

let source_json = function
  | Reported observation ->
      `Assoc ([ ("source", `String "reported") ] @ observation_json observation)
  | Absent -> `Assoc [ ("source", `String "absent") ]
  | Unavailable unavailability ->
      let reason, message =
        match unavailability with
        | Not_consulted message -> ("not_consulted", message)
        | Not_understood message -> ("not_understood", message)
      in
      `Assoc
        [
          ("source", `String "unavailable");
          ("reason", `String reason);
          ("detail", `String message);
        ]

let row_json (row : row) =
  `Assoc
    [
      ("name", `String row.name);
      ( "declaration",
        `String
          (match row.declaration with
          | Declared -> "declared"
          | Undeclared -> "undeclared") );
      ("disagreement", `Bool (disagrees row));
      ("unverified", `Bool (unverified row));
      ("docker", source_json row.docker);
      ("orchestrator", source_json row.orchestrator);
    ]

let crontab_json listing =
  `Assoc
    [
      ("summary", `String (crontab_cell listing));
      ("job_count", optional_int (Crontab_listing.job_count listing));
    ]

let server_json report =
  ( report.address,
    `Assoc
      [
        ("service", `List (List.map row_json (of_kind Service report.rows)));
        ("cron_jobs", `List (List.map row_json (of_kind Cron_job report.rows)));
        ( "infrastructure",
          `List (List.map row_json (of_kind Infrastructure report.rows)) );
        ("crontab", crontab_json report.crontab);
        ( "errors",
          `List (List.map (fun warning -> `String warning) report.warnings) );
      ] )

let render_json reports =
  Yojson.Safe.pretty_to_string (`Assoc (List.map server_json reports))

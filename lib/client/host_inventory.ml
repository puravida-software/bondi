type health =
  | Healthy
  | Unhealthy of string
  | Starting
  | No_healthcheck
  | Not_recorded
  | Unreadable of string

type container = {
  name : string;
  image : string;
  tag : string;
  state : string;
  health : health;
  restart_count : int option;
  created_at : string option;
}

type t = Observed of container list | Unreadable_listing of string

let listing_command = "ps -a --format '{{.Names}}\t{{.Image}}\t{{.State}}'"

(* Each id is inspected on its own. [docker inspect] is all-or-nothing over an
   argument list: given several, one that no longer exists takes the whole call
   non-zero and the output with it. The ids come from a listing taken a moment
   earlier, so a container pruned in the gap between the two reads would blank
   the health column for every container on the host. Inspected one at a time,
   the one that has gone costs its own line. *)
let inspection_command =
  "ps -aq | while read -r id; do docker inspect --format '{{.Name}}\t{{if \
   .Config.Healthcheck}}declared{{else}}undeclared{{end}}\t{{if \
   .State.Health}}{{.State.Health.Status}}{{else}}{{end}}\t{{.RestartCount}}\t{{.Created}}' \
   \"$id\" 2>/dev/null || true; done"

let nonempty_lines output =
  output
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")

(* The tag is what follows the last colon of the final path segment. Splitting
   on the first colon would read a registry's port as a tag, and a digest
   reference names no tag at all. *)
let split_image image =
  let name_start =
    match Bondi_common.String_utils.last_index_of_char image '/' with
    | None -> 0
    | Some index -> index + 1
  in
  let final_segment =
    String.sub image name_start (String.length image - name_start)
  in
  match Bondi_common.String_utils.last_index_of_char final_segment '@' with
  | Some _ -> (image, "")
  | None -> (
      match Bondi_common.String_utils.last_index_of_char final_segment ':' with
      | None -> (image, "")
      | Some index ->
          let colon = name_start + index in
          ( String.sub image 0 colon,
            String.sub image (colon + 1) (String.length image - colon - 1) ))

(* Health is what Docker recorded, never what the container is doing: a process
   that is up is the thing a healthcheck exists to look past. An empty field is
   the host saying there is no healthcheck at all, and a word this does not
   recognise has been read but not understood, which is no more a pass than a
   word that was never read. *)
let health_of ~declaration ~reported =
  match (declaration, reported) with
  | _, "healthy" -> Healthy
  | _, "unhealthy" -> Unhealthy reported
  | _, "starting" -> Starting
  (* Silence means two unrelated things, and only the declaration tells them
     apart: a container with no check to pass, and one whose check the host has
     not run. Read as the first, a stopped component that declares a check
     reports as having none, which is a false statement in exactly the state
     this report exists to surface. *)
  | "undeclared", "" -> No_healthcheck
  | "declared", "" -> Not_recorded
  | _, _ ->
      Unreadable
        (Printf.sprintf
           "the host reported a health this does not know: %s (healthcheck %s)"
           reported declaration)

type inspection_entry = {
  entry_declaration : string;
  entry_health : string;
  entry_restart_count : int option;
  entry_created_at : string option;
}

let optional_field value =
  match String.trim value with
  | "" -> None
  | trimmed -> Some trimmed

let inspection_entries output =
  nonempty_lines output
  |> List.filter_map (fun line ->
      match String.split_on_char '\t' line with
      | [ name; declaration; health; restart_count; created_at ] ->
          let name = String.trim name in
          let name =
            match Bondi_common.String_utils.starts_with ~prefix:"/" name with
            | true -> String.sub name 1 (String.length name - 1)
            | false -> name
          in
          Some
            ( name,
              {
                entry_declaration = String.trim declaration;
                entry_health = String.trim health;
                entry_restart_count =
                  int_of_string_opt (String.trim restart_count);
                entry_created_at = optional_field created_at;
              } )
      | []
      | [ _ ]
      | [ _; _ ]
      | [ _; _; _ ]
      | [ _; _; _; _ ]
      | _ :: _ :: _ :: _ :: _ :: _ :: _ ->
          None)

let container_of_line ~inspection line =
  match String.split_on_char '\t' line with
  | [ name; image; state ] ->
      let name = String.trim name in
      let image, tag = split_image (String.trim image) in
      let state = String.trim state in
      let health, restart_count, created_at =
        match inspection with
        | Error message -> (Unreadable message, None, None)
        | Ok entries -> (
            match List.assoc_opt name entries with
            | None ->
                ( Unreadable
                    (Printf.sprintf "the host's inspection did not report %s"
                       name),
                  None,
                  None )
            | Some entry ->
                ( health_of ~declaration:entry.entry_declaration
                    ~reported:entry.entry_health,
                  entry.entry_restart_count,
                  entry.entry_created_at ))
      in
      Some { name; image; tag; state; health; restart_count; created_at }
  | []
  | [ _ ]
  | [ _; _ ]
  | _ :: _ :: _ :: _ :: _ ->
      None

(* Only the host saying there is no check to pass takes a container off the
   list. Every other reading leaves something to wait for, an unreadable one
   included: a read that failed has not said the container has no healthcheck,
   and a wait re-reads, so it answers that question rather than guessing at
   it. *)
let has_something_to_wait_for = function
  | No_healthcheck -> false
  | Healthy
  | Unhealthy _
  | Starting
  | Not_recorded
  | Unreadable _ ->
      true

let running_state = "running"

(* A container that is not running is not waited on at all, whatever its health
   says. There is nothing for a wait to observe: it would read the state, find
   it is not running and come straight back, having spent a remote session to
   repeat what this listing already carries — and having produced a verdict that
   fails the run. A cron job's container is [exited] between runs by design, so
   the alternative fails every host with a schedule. *)
let is_running container = String.equal container.state running_state

let health_to_wait_for = function
  | Unreadable_listing _ -> []
  | Observed containers ->
      containers
      |> List.filter (fun container ->
          is_running container && has_something_to_wait_for container.health)
      |> List.map (fun container -> container.name)

let of_reads ~listing ~inspection =
  match listing with
  | Error message -> Unreadable_listing message
  | Ok output ->
      let inspection = Result.map inspection_entries inspection in
      Observed
        (List.filter_map
           (container_of_line ~inspection)
           (nonempty_lines output))

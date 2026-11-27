open Alcotest
module Acme_file = Bondi_client.Acme_file
module Remote_exec = Bondi_client.Remote_exec
module Setup_phases = Bondi_client.Setup_phases

let contains ~needle haystack =
  Bondi_common.String_utils.contains ~needle haystack

let transport_error =
  Remote_exec.message
    (Remote_exec.Ssh_failed
       { code = 255; output = "Connection closed by 203.0.113.9 port 22" })

let acme_path = Bondi_common.Defaults.acme_file_path
let state answer = Acme_file.state_of_probe ~expected:Acme_file.declared answer

let state_name = function
  | Acme_file.As_declared -> "as declared"
  | Acme_file.Differs { observed } ->
      "differs: " ^ Bondi_client.Host_answer.to_string observed
  | Acme_file.Absent -> "absent"
  | Acme_file.Undetermined message -> "undetermined: " ^ message

let present_answer reading =
  Ok (Printf.sprintf "%s %s\n" Acme_file.present_marker reading)

(* A non-zero [test -f] is the channel a dropped connection arrives on as well,
   so the answer and the failure to get one were the same value. *)
let test_probe_error_is_not_an_absent_file () =
  match state (Error transport_error) with
  | Acme_file.Undetermined message ->
      check bool "carries the probe's own text" true
        (contains ~needle:"Connection closed by 203.0.113.9 port 22" message)
  | (Acme_file.As_declared | Acme_file.Differs _ | Acme_file.Absent) as s ->
      failf "a read that never happened said something: %s" (state_name s)

(* Every answer the probe can give, told apart on the one builder. *)
let test_probe_reports_what_the_host_said () =
  check string "a file at what Bondi declares" "as declared"
    (state_name (state (present_answer "root:root 600")));
  check string "a file at another mode, as the host printed it"
    "differs: root:root 644"
    (state_name (state (present_answer "root:root 644")));
  check string "a file another user owns" "differs: deploy:deploy 600"
    (state_name (state (present_answer "deploy:deploy 600")));
  check string "a file that is not there" "absent"
    (state_name (state (Ok (Acme_file.absent_marker ^ "\n"))));
  check string "a marker on a line after a banner still answers" "absent"
    (state_name (state (Ok ("Welcome\n" ^ Acme_file.absent_marker ^ "\n"))))

(* An answer carrying neither marker never said which. The probe prints nothing
   when it could not tell (a non-regular file, an unsearchable parent, a sudo
   that could not run), and that is exactly what must not become a creation. *)
let test_probe_without_a_marker_is_undetermined () =
  let undetermined answer =
    match state answer with
    | Acme_file.Undetermined _ -> true
    | Acme_file.As_declared
    | Acme_file.Differs _
    | Acme_file.Absent ->
        false
  in
  check bool "silence" true (undetermined (Ok ""));
  check bool "only whitespace" true (undetermined (Ok "\n  \n"));
  check bool "a banner" true (undetermined (Ok "Welcome to Ubuntu 22.04 LTS\n"));
  check bool "an unknown marker" true (undetermined (Ok "BONDI_ACME_MAYBE\n"));
  check bool "the present marker alone" true
    (undetermined (Ok (Acme_file.present_marker ^ "\n")))

(* The command carries the whole distinction, so it is pinned here: it names the
   file quoted, runs under sudo, and prints absent only on a positive answer. *)
let test_probe_command_asks_for_both_answers () =
  let command = Acme_file.probe_command ~path:"/etc/traefik/acme/acme.json" in
  let carries needle = contains ~needle command in
  check bool "names the file it is asking about, quoted" true
    (carries "'/etc/traefik/acme/acme.json'");
  check bool "can say the host has it" true (carries Acme_file.present_marker);
  check bool "and can say the host does not" true
    (carries Acme_file.absent_marker);
  check bool "asks for owner, group and mode in the declared shape" true
    (carries "stat -c '%U:%G %a'");
  check bool "tests as root, like the writes" true
    (carries "sudo test -f '/etc/traefik/acme/acme.json'");
  check bool "says absent only when the path is positively not there" true
    (carries
       "elif sudo test ! -e '/etc/traefik/acme/acme.json'; then echo \
        BONDI_ACME_ABSENT; fi");
  check bool "has no else arm that answers absent for anything else" false
    (carries "else echo")

let test_write_commands_quote_the_path () =
  let path = "/etc/traefik/acme dir/acme.json" in
  check string "permissions"
    "sudo chown root:root '/etc/traefik/acme dir/acme.json' && sudo chmod 600 \
     '/etc/traefik/acme dir/acme.json'"
    (Acme_file.permissions_command ~path);
  check string "create"
    "sudo mkdir -p '/etc/traefik/acme dir' && sudo touch '/etc/traefik/acme \
     dir/acme.json' && sudo chown root:root '/etc/traefik/acme dir/acme.json' \
     && sudo chmod 600 '/etc/traefik/acme dir/acme.json'"
    (Acme_file.create_command ~path)

let course_name = function
  | Acme_file.Keep -> "keep"
  | Acme_file.Correct { command = _; found } ->
      "correct from " ^ Bondi_client.Host_answer.to_string found
  | Acme_file.Create { command = _ } -> "create"
  | Acme_file.Refuse _ -> "refuse"

let test_reading () =
  check string "present and right: no write" "keep"
    (course_name
       (Acme_file.course ~path:acme_path
          (state (present_answer "root:root 600"))));
  (match
     Acme_file.course ~path:acme_path (state (present_answer "root:root 644"))
   with
  | Acme_file.Correct { command; found } -> (
      let carries needle = contains ~needle command in
      check bool "sets the declared owner" true
        (carries "chown root:root '/etc/traefik/acme/acme.json'");
      check bool "sets the declared mode" true
        (carries "chmod 600 '/etc/traefik/acme/acme.json'");
      let confirmed =
        Acme_file.confirmation ~path:acme_path ~server:"10.0.0.1" ~found
          (state (present_answer "root:root 600"))
      in
      (match confirmed with
      | Ok correction ->
          check (list string) "the correction says what was found and applied"
            [
              "/etc/traefik/acme/acme.json on server 10.0.0.1 was owner and \
               mode root:root 644, applied root:root 600";
            ]
            (Setup_phases.corrections_report ~server:"10.0.0.1" [ correction ]);
          check string "and the run lists it"
            "setup changed on server 10.0.0.1: ACME file permissions corrected"
            (Bondi_client.Setup_changes.closing_line ~server:"10.0.0.1"
               (List.filter_map Bondi_client.Setup_changes.of_correction
                  [ correction ]))
      | Error message -> failf "a read-back that agreed failed: %s" message);
      (match
         Acme_file.confirmation ~path:acme_path ~server:"10.0.0.1" ~found
           (state (present_answer "root:root 644"))
       with
      | Ok _ -> fail "a read-back that still differs is not a correction"
      | Error message ->
          check bool "says what the host still reports" true
            (contains ~needle:"root:root 644" message);
          check bool "names the server" true
            (contains ~needle:"10.0.0.1" message));
      match
        Acme_file.confirmation ~path:acme_path ~server:"10.0.0.1" ~found
          (state (Error transport_error))
      with
      | Ok _ -> fail "a read-back that never happened is not a correction"
      | Error message ->
          check bool "carries why it could not be read" true
            (contains ~needle:"Connection closed by 203.0.113.9 port 22" message)
      )
  | (Acme_file.Keep | Acme_file.Create _ | Acme_file.Refuse _) as course ->
      failf "present and wrong is a correction, not %s" (course_name course));
  (match
     Acme_file.course ~path:acme_path
       (state (Ok (Acme_file.absent_marker ^ "\n")))
   with
  | Acme_file.Create { command } ->
      check bool "creates the file it reads" true
        (contains ~needle:"touch '/etc/traefik/acme/acme.json'" command)
  | (Acme_file.Keep | Acme_file.Correct _ | Acme_file.Refuse _) as course ->
      failf "absent is a creation, not %s" (course_name course));
  match Acme_file.course ~path:acme_path (state (Ok "")) with
  | Acme_file.Refuse message ->
      check bool "names the file it could not read" true
        (contains ~needle:acme_path message)
  | (Acme_file.Keep | Acme_file.Correct _ | Acme_file.Create _) as course ->
      failf "an unread file is refused, not %s" (course_name course)

(* A creation is recorded only once the read-back finds the declared posture:
   a command exiting zero is not the host having applied it. *)
let test_created_file_is_confirmed_by_a_read_back () =
  let confirmed s = Acme_file.confirmed ~path:acme_path ~server:"10.0.0.1" s in
  check bool "at the declared posture" true
    (Result.is_ok (confirmed (state (present_answer "root:root 600"))));
  let refused label s =
    match confirmed s with
    | Ok () -> failf "%s was confirmed" label
    | Error message ->
        check bool
          (label ^ " names the server")
          true
          (contains ~needle:"10.0.0.1" message)
  in
  refused "a file at another mode" (state (present_answer "root:root 644"));
  refused "a file still absent" (state (Ok (Acme_file.absent_marker ^ "\n")));
  refused "a read-back that failed" (state (Error transport_error));
  refused "a read-back that said nothing" (state (Ok ""))

let () =
  run "acme_file"
    [
      ( "acme probe",
        [
          test_case "a failed probe is not an absent file" `Quick
            test_probe_error_is_not_an_absent_file;
          test_case "present and absent are told apart" `Quick
            test_probe_reports_what_the_host_said;
          test_case "an answer with no marker is undetermined" `Quick
            test_probe_without_a_marker_is_undetermined;
          test_case "the command asks for both answers" `Quick
            test_probe_command_asks_for_both_answers;
          test_case "the writes quote the path" `Quick
            test_write_commands_quote_the_path;
          test_case "each reading calls for its own write" `Quick test_reading;
          test_case "a creation is confirmed by a read-back" `Quick
            test_created_file_is_confirmed_by_a_read_back;
        ] );
    ]

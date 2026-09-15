open Alcotest
module Remote_exec = Bondi_client.Remote_exec

let contains = Test_helpers.contains
let joined () = String.concat " " (Remote_exec.multiplex_options ())

(* The ControlPath option located by name rather than by position. An index into
   the option list is a claim about the order that nothing enforces: insert one
   option ahead of it and both assertions below quietly move to the wrong
   string, which is the failure they exist to catch. *)
let control_path_option () =
  match
    List.find_opt
      (fun option -> contains ~needle:"ControlPath=" option)
      (Remote_exec.multiplex_options ())
  with
  | Some option -> option
  | None -> Alcotest.fail "the option set carries no ControlPath"

let test_reuses_one_connection () =
  let s = joined () in
  check bool "ControlMaster=auto" true (contains ~needle:"ControlMaster=auto" s);
  check bool "ControlPersist set" true (contains ~needle:"ControlPersist=" s);
  check bool "ControlPath set" true (contains ~needle:"ControlPath=" s)

(* The path the option names, with the quoting this module added taken back off.
   Read by three cases below, each of which is about a different property of the
   same string. *)
let control_path () =
  let opt = control_path_option () in
  match String.index_opt opt '=' with
  | None -> Alcotest.fail ("ControlPath option carries no '=': " ^ opt)
  | Some i ->
      String.sub opt (i + 1) (String.length opt - i - 1)
      |> String.split_on_char '\''
      |> String.concat ""

(* One socket per process is one socket for every server that process talks to.
   `bondi init` scaffolds two servers and every command loops them inside one
   process, well inside ControlPersist -- so the second server's commands run
   down the first server's connection, past the `-i`, the `IdentitiesOnly=yes`
   and the agent that were all chosen for the second. Demonstrated with two
   sshds, one on 127.0.0.1 and one on 127.0.0.2, each answering with its own
   name: the second connection answered with the first's.

   The token is what ssh expands per connection, and it has to be ssh that
   expands it: the client spells one option set for the whole run, and the
   connection is not known where the option is written. *)
let connection_token = "%C"

let test_path_is_per_connection () =
  let path = control_path () in
  check bool
    ("names the connection rather than only the process: " ^ path)
    true
    (contains ~needle:connection_token path)

(* A control socket is a Unix domain socket, whose path is limited to about 104
   bytes. Exceeding it fails with "unix_listener: path too long" -- and the
   master simply never starts, so every command silently falls back to a full
   handshake and the option appears to do nothing.

   What the kernel is asked to bind is the expanded path, not the one this
   module spells: %C becomes a 40-character hash [observed under
   OpenSSH_10.5p1], so the literal is 38 bytes shorter than the thing the limit
   applies to and asserting on the literal would assert on the wrong string. *)
let token_width = 40
let sun_path_limit = 104

let test_path_is_short_enough () =
  let path = control_path () in
  let expanded =
    Filename.concat (Filename.dirname path) (String.make token_width 'a')
  in
  check bool
    ("under the sun_path limit once expanded: " ^ expanded)
    true
    (String.length expanded < sun_path_limit)

(* Whoever can open the socket can multiplex onto the connection it holds, which
   is root on a deploy box. All 16 fleet agents run as one uid, so a predictable
   path in a shared /tmp would let one repo's job ride another's deploy. *)
let test_socket_dir_is_private () =
  let dir = Filename.dirname (control_path ()) in
  check bool "directory exists" true (Sys.file_exists dir);
  let st = Unix.stat dir in
  check int "mode 0700" 0o700 (st.Unix.st_perm land 0o777);
  check bool "named after this process" true
    (contains ~needle:(string_of_int (Unix.getpid ())) dir)

let test_stable_within_a_process () =
  check (list string) "same options on every call"
    (Remote_exec.multiplex_options ())
    (Remote_exec.multiplex_options ())

(* The affirmative arm for the split is [test_reuses_one_connection] above; this
   is the negative one. Reading the shared options must not set up a control
   socket, because taking them costs nothing while taking the multiplex set
   creates a mode-700 directory on the first call. Fold the two together and
   every reader of the connection bounds -- including the cases that only assert
   those bounds -- acquires that side effect. *)
let test_shared_options_do_not_multiplex () =
  let shared = String.concat " " Remote_exec.ssh_options in
  check bool "shared options have no ControlMaster" false
    (contains ~needle:"ControlMaster" shared);
  check bool "shared options have no ControlPath" false
    (contains ~needle:"ControlPath" shared)

let () =
  run "ssh multiplexing"
    [
      ( "options",
        [
          test_case "reuses one connection" `Quick test_reuses_one_connection;
          test_case "path is per connection" `Quick test_path_is_per_connection;
          test_case "path short enough" `Quick test_path_is_short_enough;
          test_case "socket dir is private" `Quick test_socket_dir_is_private;
          test_case "stable within a process" `Quick
            test_stable_within_a_process;
          test_case "shared options opt out" `Quick
            test_shared_options_do_not_multiplex;
        ] );
    ]

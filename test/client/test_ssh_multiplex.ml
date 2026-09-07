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

(* A control socket is a Unix domain socket, whose path is limited to about 104
   bytes. Exceeding it fails with "unix_listener: path too long" -- and the
   master simply never starts, so every command silently falls back to a full
   handshake and the option appears to do nothing. *)
let test_path_is_short_enough () =
  let dir = control_path_option () in
  check bool ("under the sun_path limit: " ^ dir) true (String.length dir < 100)

(* Whoever can open the socket can multiplex onto the connection it holds, which
   is root on a deploy box. All 16 fleet agents run as one uid, so a predictable
   path in a shared /tmp would let one repo's job ride another's deploy. *)
let test_socket_dir_is_private () =
  let opt = control_path_option () in
  let path =
    match String.index_opt opt '=' with
    | None -> Alcotest.fail ("ControlPath option carries no '=': " ^ opt)
    | Some i ->
        String.sub opt (i + 1) (String.length opt - i - 1)
        |> String.split_on_char '\''
        |> String.concat ""
  in
  let dir = Filename.dirname path in
  check bool "directory exists" true (Sys.file_exists dir);
  let st = Unix.stat dir in
  check int "mode 0700" 0o700 (st.Unix.st_perm land 0o777);
  check bool "named after this process" true
    (contains ~needle:(string_of_int (Unix.getpid ())) dir)

let test_stable_within_a_process () =
  check (list string) "same options on every call"
    (Remote_exec.multiplex_options ())
    (Remote_exec.multiplex_options ())

(* A tunnel is one long-lived connection; routing it through a shared master
   would make teardown a question of channels rather than killing a process. *)
let test_tunnel_does_not_multiplex () =
  let cmd =
    Bondi_client.Ssh_tunnel.tunnel_command ~key_path:"/tmp/k" ~user:"root"
      ~host:"203.0.113.1" ~local_port:1234 ~remote_port:3030
  in
  check bool "tunnel has no ControlMaster" false
    (contains ~needle:"ControlMaster" cmd)

let () =
  run "ssh multiplexing"
    [
      ( "options",
        [
          test_case "reuses one connection" `Quick test_reuses_one_connection;
          test_case "path short enough" `Quick test_path_is_short_enough;
          test_case "socket dir is private" `Quick test_socket_dir_is_private;
          test_case "stable within a process" `Quick
            test_stable_within_a_process;
          test_case "tunnel opts out" `Quick test_tunnel_does_not_multiplex;
        ] );
    ]

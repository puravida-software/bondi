module Docker = Bondi_server__Docker__Client

let mk_container ~id ~image ~names ?(image_id = "sha256:test")
    ?(state = Some "running") ?(status = Some "Up") ?(labels = None) () :
    Docker.container =
  { Docker.id; image; image_id; names; state; status; labels }

let mk_health_state ?(failing_streak = 0) ?(log = []) status :
    Docker.health_state =
  { status; failing_streak; log }

let mk_inspect ~created_at ~restart_count ~status ?(exit_code = 0)
    ?(health = None) ?(host_config = None) ?(networks = None) () :
    Docker.inspect_response =
  {
    created_at;
    restart_count;
    state = { status; exit_code; health };
    host_config;
    network_settings = Option.map (fun networks -> { Docker.networks }) networks;
  }

let mount_testable : Docker.mount Alcotest.testable =
  Alcotest.testable
    (fun fmt (m : Docker.mount) ->
      Format.fprintf fmt "{%s %s -> %s ro=%b}" m.type_ m.source m.target
        m.read_only)
    ( = )

let host_config_testable : Docker.host_config Alcotest.testable =
  Alcotest.testable
    (fun fmt host_config ->
      Format.pp_print_string fmt
        (Yojson.Safe.to_string (Docker.host_config_to_yojson host_config)))
    ( = )

(* Every capture is the body a real Docker Engine returned for
   [GET /images/{name}/json], saved byte for byte; how each image was built and
   captured is in [fixtures/image_inspect/README.md]. Each image is read at
   v1.41, the version negotiation picks on today's engines, where
   [ContainerConfig] is still sent but null, and at v1.45, the first version that
   no longer sends it at all. The path is resolved from the test executable, so
   the read holds under [dune runtest], which is what copies the captures next
   to the executable. *)
let capture_versions = [ "v1.41"; "v1.45" ]

let image_inspect_capture_body ~kind ~version =
  let name = Printf.sprintf "%s.%s.json" kind version in
  let path =
    Filename.concat
      (Filename.dirname Sys.executable_name)
      (Filename.concat "fixtures" (Filename.concat "image_inspect" name))
  in
  In_channel.with_open_bin path In_channel.input_all

let image_inspect_capture ~kind ~version =
  let name = Printf.sprintf "%s.%s.json" kind version in
  let body = image_inspect_capture_body ~kind ~version in
  match
    Docker.image_inspect_response_of_yojson (Yojson.Safe.from_string body)
  with
  | Ok response -> response
  | Error msg ->
      Alcotest.fail (Printf.sprintf "%s does not decode: %s" name msg)

(* An in-memory Docker socket. The client opens one connection per request, so
   each connection reads one request off its writes, records its method,
   target and body, and answers it once from [respond]. What a test asserts is
   the list of requests the deploy made, which is what "nothing moved" means,
   and, where what was created matters, the body it was created with. *)
module Fake_engine = struct
  type t = {
    mutable requests : (string * string * string) list;
        (* mutable: justified because each connection's reader appends the
           request it answered, from inside the client's own call, and the test
           reads the whole list once the deploy returns. *)
  }

  let calls t =
    List.rev_map (fun (meth, target, _) -> (meth, target)) t.requests

  (* Every request as method, target and body, in the order made. The body is
     what followed the head, as written to the socket. *)
  let calls_with_bodies t = List.rev t.requests

  let header_end s =
    let rec go i =
      if i + 4 > String.length s then None
      else if String.sub s i 4 = "\r\n\r\n" then Some (i + 4)
      else go (i + 1)
    in
    go 0

  let content_length head =
    String.split_on_char '\n' head
    |> List.find_map (fun line ->
        match String.index_opt line ':' with
        | Some i
          when String.lowercase_ascii (String.trim (String.sub line 0 i))
               = "content-length" ->
            int_of_string_opt
              (String.trim
                 (String.sub line (i + 1) (String.length line - i - 1)))
        | _ -> None)
    |> Option.value ~default:0

  (* The request is complete once its head and a declared body are in. A chunked
     body is complete at its terminating chunk. *)
  let complete s =
    match header_end s with
    | None -> false
    | Some body_at ->
        let head = String.lowercase_ascii (String.sub s 0 body_at) in
        if Bondi_common.String_utils.contains ~needle:"chunked" head then
          String.ends_with ~suffix:"0\r\n\r\n" s
        else String.length s - body_at >= content_length head

  (* The connection is an [Eio_mock.Flow], not a hand-written
     [Eio.Net.Pi.stream_socket]: that interface gained members across eio
     releases, and a fake that implements it breaks on the next one. The mock's
     [pp] is called with every string written to it, in order, which is how the
     request is recovered; its first read waits for the whole request and
     answers it, and later reads fall back to the mock's default End_of_file. *)
  let answer_for engine ~respond request =
    let line =
      match String.split_on_char '\r' request with
      | first :: _ -> String.trim first
      | [] -> ""
    in
    let meth, target =
      match String.split_on_char ' ' line with
      | m :: target :: _ -> (m, target)
      | _ -> ("?", "?")
    in
    let body =
      match header_end request with
      | Some body_at ->
          String.sub request body_at (String.length request - body_at)
      | None -> ""
    in
    engine.requests <- (meth, target, body) :: engine.requests;
    let code, body = respond meth target in
    Printf.sprintf
      "HTTP/1.1 %d X\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" code
      (String.length body) body

  let make ~respond =
    let engine = { requests = [] } in
    let net = Eio_mock.Net.make "docker" in
    let socket () =
      let written = Buffer.create 256 in
      let answered = ref false in
      let flow =
        Eio_mock.Flow.make
          ~pp:(fun _ s -> if not !answered then Buffer.add_string written s)
          "docker-conn"
      in
      let rec read () =
        let request = Buffer.contents written in
        if complete request then (
          answered := true;
          answer_for engine ~respond request)
        else (
          Eio.Fiber.yield ();
          read ())
      in
      Eio_mock.Flow.on_read flow [ `Run read ];
      (flow :> _ Eio.Net.stream_socket)
    in
    Eio_mock.Net.on_connect net (List.init 400 (fun _ -> `Run socket));
    (engine, net)
end

let ( let* ) = Result.bind

let contains ~needle hay =
  let len_h = String.length hay in
  let len_n = String.length needle in
  let rec loop idx =
    if idx + len_n > len_h then false
    else if String.sub hay idx len_n = needle then true
    else loop (idx + 1)
  in
  if len_n = 0 then true else loop 0

let starts_with ~prefix value =
  let len_prefix = String.length prefix in
  String.length value >= len_prefix && String.sub value 0 len_prefix = prefix

let read_all ic =
  let buffer = Buffer.create 256 in
  (try
     while true do
       let line = input_line ic in
       Buffer.add_string buffer line;
       Buffer.add_char buffer '\n'
     done
   with
  | End_of_file -> ());
  Buffer.contents buffer

let run_command cmd =
  let in_chan, out_chan, err_chan =
    Unix.open_process_full cmd (Unix.environment ())
  in
  close_out_noerr out_chan;
  let stdout = read_all in_chan in
  let stderr = read_all err_chan in
  match Unix.close_process_full (in_chan, out_chan, err_chan) with
  | Unix.WEXITED 0 -> Ok stdout
  | Unix.WEXITED code ->
      Error (Printf.sprintf "command failed (%d): %s" code (String.trim stderr))
  | Unix.WSIGNALED signal ->
      Error
        (Printf.sprintf "command killed (%d): %s" signal (String.trim stderr))
  | Unix.WSTOPPED signal ->
      Error
        (Printf.sprintf "command stopped (%d): %s" signal (String.trim stderr))

let decode_private_key contents =
  match Base64.decode contents with
  | Ok decoded -> decoded
  | Error _ -> contents

let with_temp_key contents f =
  let path = Filename.temp_file "bondi-key-" ".pem" in
  let decoded = decode_private_key contents in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      Sys.remove path)
    (fun () ->
      output_string oc decoded;
      close_out oc;
      Unix.chmod path 0o600;
      f path)

let remote_run ~user ~host ~key_path cmd =
  let destination = user ^ "@" ^ host in
  let ssh_cmd =
    Printf.sprintf
      "ssh -i %s -o BatchMode=yes -o StrictHostKeyChecking=accept-new %s -- %s"
      (Filename.quote key_path)
      (Filename.quote destination)
      (Filename.quote cmd)
  in
  run_command ssh_cmd

let get_docker_version ~user ~host ~key_path =
  remote_run ~user ~host ~key_path "docker --version"

let run_remote_docker ~user ~host ~key_path cmd =
  remote_run ~user ~host ~key_path ("docker " ^ cmd)

let get_running_version ~user ~host ~key_path =
  match
    run_remote_docker ~user ~host ~key_path
      "ps --filter name=^/bondi$ --format '{{.Image}}'"
  with
  | Error _ as err -> err
  | Ok output ->
      let image =
        output
        |> String.split_on_char '\n'
        |> List.find_opt (fun line -> String.trim line <> "")
        |> Option.value ~default:""
        |> String.trim
      in
      let prefix = "mlopez1506/bondi-server:" in
      if image = "" then Ok ""
      else if starts_with ~prefix image then
        let version =
          String.sub image (String.length prefix)
            (String.length image - String.length prefix)
        in
        Ok (String.trim version)
      else Ok image

let setup_server config server =
  let open Config_file in
  let { ip_address; ssh } = server in
  print_endline ("Processing server: " ^ ip_address);
  match ssh with
  | None ->
      prerr_endline ("Missing ssh configuration for server " ^ ip_address);
      Error "missing ssh configuration"
  | Some ssh_config ->
      with_temp_key ssh_config.private_key_contents (fun key_path ->
          let user = ssh_config.user in
          let host = ip_address in
          let ensure_docker () =
            match get_docker_version ~user ~host ~key_path with
            | Ok version_output ->
                if contains ~needle:"command not found" version_output then
                  Error "docker not installed"
                else (
                  print_endline
                    (Printf.sprintf
                       "Docker is already installed on server %s: %s" ip_address
                       (String.trim version_output));
                  Ok ())
            | Error err ->
                print_endline
                  (Printf.sprintf
                     "Docker not found on server %s\n\
                      Error: %s\n\
                      Installing Docker..."
                     ip_address err);
                let install_cmd =
                  "curl -fsSL https://get.docker.com -o get-docker.sh && sudo \
                   sh get-docker.sh"
                in
                let* output = remote_run ~user ~host ~key_path install_cmd in
                print_endline
                  (Printf.sprintf "Docker installed on server %s: %s" ip_address
                     (String.trim output));
                Ok ()
          in
          let ensure_acme_file () =
            let acme_dir = "/etc/traefik/acme" in
            let acme_file = acme_dir ^ "/acme.json" in
            match remote_run ~user ~host ~key_path ("test -f " ^ acme_file) with
            | Ok _ ->
                let cmd =
                  Printf.sprintf "sudo chown root:root %s && sudo chmod 600 %s"
                    acme_file acme_file
                in
                let* _ = remote_run ~user ~host ~key_path cmd in
                print_endline
                  (Printf.sprintf
                     "ACME file permissions updated on server %s: %s" ip_address
                     acme_file);
                Ok ()
            | Error _ ->
                let cmd =
                  Printf.sprintf
                    "sudo mkdir -p %s && sudo touch %s && sudo chown root:root \
                     %s && sudo chmod 600 %s"
                    acme_dir acme_file acme_file acme_file
                in
                let* output = remote_run ~user ~host ~key_path cmd in
                print_endline
                  (Printf.sprintf "ACME file created on server %s: %s"
                     ip_address (String.trim output));
                Ok ()
          in
          let ensure_server_version () =
            let* running = get_running_version ~user ~host ~key_path in
            if running <> "" && running = config.bondi_server.version then (
              print_endline
                (Printf.sprintf
                   "bondi-server Docker image is already running on server %s: \
                    %s, skipping..."
                   ip_address running);
              Ok `Skip)
            else if running <> "" then (
              print_endline
                (Printf.sprintf
                   "bondi-server Docker image version mismatch on server %s: \
                    running %s, want %s, stopping current server to run the \
                    new version..."
                   ip_address running config.bondi_server.version);
              let* _ = run_remote_docker ~user ~host ~key_path "stop bondi" in
              print_endline
                (Printf.sprintf "Stopped bondi-server Docker image on server %s"
                   ip_address);
              Ok `Run)
            else Ok `Run
          in
          let run_server () =
            let run_cmd =
              "docker run -d --name bondi -p 3030:3030 -v \
               /var/run/docker.sock:/var/run/docker.sock --group-add $(stat -c \
               %g /var/run/docker.sock) --rm mlopez1506/bondi-server:"
              ^ config.bondi_server.version
            in
            let* output = remote_run ~user ~host ~key_path run_cmd in
            print_endline
              (Printf.sprintf
                 "bondi-server docker image started on server %s: %s" ip_address
                 (String.trim output));
            Ok ()
          in
          match ensure_docker () with
          | Error err -> Error err
          | Ok () -> (
              match ensure_acme_file () with
              | Error err -> Error err
              | Ok () -> (
                  match ensure_server_version () with
                  | Error err -> Error err
                  | Ok `Skip -> Ok ()
                  | Ok `Run -> run_server ())))

let run () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config ->
      print_endline "Setting up the servers...";
      let results =
        List.map (setup_server config) config.user_service.servers
      in
      if
        List.exists
          (function
            | Error _ -> true
            | Ok () -> false)
          results
      then exit 1

let cmd =
  let term = Cmdliner.Term.(const run $ const ()) in
  let info = Cmdliner.Cmd.info "setup" ~doc:"Set up Bondi for a project." in
  Cmdliner.Cmd.v info term

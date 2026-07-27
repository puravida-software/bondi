(* --fail-with-body was added in curl 7.76.0. Kept as a pair rather than a
   string so the comparison below is numeric: "7.9" is newer than "7.76" under
   string ordering and older under the ordering that matters. *)
let minimum_major = 7
let minimum_minor = 76
let minimum_string = "7.76"

(* [curl --version] prints "curl <version> (<triple>) libcurl/..." on its first
   line. Only the first two components are read: the patch level never gates an
   option, and a vendor suffix such as "8.5.0-DEV" must not make the line
   unreadable. *)
let version_of_output output =
  let first_line =
    match String.split_on_char '\n' output with
    | [] -> ""
    | line :: _ -> line
  in
  match String.split_on_char ' ' (String.trim first_line) with
  | "curl" :: version :: _ -> (
      match String.split_on_char '.' version with
      | major :: minor :: _ -> (
          match (int_of_string_opt major, int_of_string_opt minor) with
          | Some major, Some minor -> Some (version, major, minor)
          | Some _, None
          | None, Some _
          | None, None ->
              None)
      | []
      | [ _ ] ->
          None)
  | []
  | _ :: _ ->
      None

let supports_fail_with_body output =
  match version_of_output output with
  | None ->
      Error
        (Printf.sprintf
           "could not read a curl version from the server; curl %s or later is \
            required, because bondi's crontab command uses --fail-with-body. \
            The server answered: %s"
           minimum_string (String.trim output))
  | Some (version, major, minor) ->
      if
        major > minimum_major
        || (major = minimum_major && minor >= minimum_minor)
      then Ok ()
      else
        Error
          (Printf.sprintf
             "the server has curl %s, but bondi's crontab command uses \
              --fail-with-body, which requires curl %s or later. An older curl \
              rejects it as an unknown option, so every scheduled job would \
              fail. Upgrade curl on the server, then run bondi setup again."
             version minimum_string)
